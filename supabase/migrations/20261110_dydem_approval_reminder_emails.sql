
-- DYDEM: recordatorios de aprobación pendientes, gestionados solo por Administrador.
-- Correos transaccionales Resend; credencial cifrada en Supabase Vault, jamás en GitHub.
create schema if not exists dydem_internal;
revoke all on schema dydem_internal from public,anon,authenticated;

alter table public.profiles
 add column if not exists approval_reminders_enabled boolean not null default true;

create table if not exists dydem_internal.reminder_config (
 id integer primary key default 1 check (id=1),
 enabled boolean not null default false,
 from_address text not null default '',
 resend_key_id uuid,
 updated_at timestamptz not null default now(),
 updated_by uuid
);
insert into dydem_internal.reminder_config(id,enabled) values(1,false) on conflict(id) do nothing;
alter table dydem_internal.reminder_config enable row level security;
revoke all on dydem_internal.reminder_config from public,anon,authenticated;

create table if not exists dydem_internal.reminder_log(
 id bigint generated always as identity primary key,
 user_id uuid not null,
 reminder_date date not null,
 items_count integer not null default 0,
 status text not null default 'queued' check(status in ('queued','accepted','failed')),
 request_id bigint,
 attempts integer not null default 0,
 last_error text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(user_id,reminder_date)
);
alter table dydem_internal.reminder_log enable row level security;
revoke all on dydem_internal.reminder_log from public,anon,authenticated;
create index if not exists dydem_reminder_status_request_idx
 on dydem_internal.reminder_log(status,request_id) where status='queued';

create or replace function public.dydem_reminder_admin_settings()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $body$
declare cfg dydem_internal.reminder_config%rowtype;
begin
 if not public.is_dydem_admin() then
  raise exception 'Solo Administrador puede consultar la configuración de correos' using errcode='42501';
 end if;
 select * into cfg from dydem_internal.reminder_config where id=1;
 return jsonb_build_object(
  'enabled',cfg.enabled,
  'configured',cfg.resend_key_id is not null and cfg.from_address<>'',
  'sender',cfg.from_address,
  'local_time','08:00',
  'timezone','America/Mexico_City',
  'recipients',(select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'name',coalesce(nullif(p.display_name,''),p.email),
   'email',p.email,'active',p.active,'enabled',p.approval_reminders_enabled
  ) order by p.display_name,p.email),'[]'::jsonb) from public.profiles p),
  'delivery_summary',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from
    (select l.reminder_date,l.status,count(*) as total from dydem_internal.reminder_log l
      group by l.reminder_date,l.status order by l.reminder_date desc limit 12) x)
 );
end $body$;

create or replace function public.dydem_set_reminder_config(
 p_enabled boolean,
 p_from_address text default null,
 p_resend_api_key text default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $body$
declare cfg dydem_internal.reminder_config%rowtype;
 v_sender text;v_key text;v_secret uuid;
begin
 if not public.is_dydem_admin() then
  raise exception 'Solo Administrador puede cambiar los recordatorios' using errcode='42501';
 end if;
 if p_enabled is null then raise exception 'Indica si los correos estarán activos';end if;
 select * into cfg from dydem_internal.reminder_config where id=1 for update;
 v_sender:=coalesce(nullif(btrim(p_from_address),''),cfg.from_address);
 if v_sender<>'' and (length(v_sender)>250 or
    v_sender !~* '^[a-z0-9._%+\-]+@[a-z0-9\-]+(\.[a-z0-9\-]+)+$') then
  raise exception 'El remitente debe ser un correo válido de un dominio verificado en Resend';
 end if;
 v_secret:=cfg.resend_key_id;
 v_key:=nullif(btrim(p_resend_api_key),'');
 if v_key is not null then
  if left(v_key,3)<>'re_' or length(v_key)<10 or length(v_key)>250 then
   raise exception 'La clave de Resend no tiene un formato válido';
  end if;
  if v_secret is null then
    v_secret:=vault.create_secret(v_key,'dydem_resend_approval_reminders','Credencial exclusiva para recordatorios DYDEM');
  else
    perform vault.update_secret(v_secret,v_key);
  end if;
 end if;
 if p_enabled and (v_secret is null or v_sender='') then
   raise exception 'Antes de activar, configura el remitente verificado y una clave de Resend';
 end if;
 update dydem_internal.reminder_config
 set enabled=p_enabled,from_address=v_sender,resend_key_id=v_secret,
     updated_at=now(),updated_by=auth.uid() where id=1;
 return public.dydem_reminder_admin_settings();
end $body$;

create or replace function public.dydem_set_user_reminders(
 p_user_id uuid,p_enabled boolean
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $body$
declare p public.profiles%rowtype;
begin
 if not public.is_dydem_admin() then
  raise exception 'Solo Administrador puede activar/desactivar correos por usuario' using errcode='42501';
 end if;
 if p_user_id is null or p_enabled is null then raise exception 'Selecciona el usuario y el estado';end if;
 update public.profiles set approval_reminders_enabled=p_enabled
 where id=p_user_id returning * into p;
 if not found then raise exception 'Usuario inexistente';end if;
 return jsonb_build_object('id',p.id,'name',p.display_name,'enabled',p.approval_reminders_enabled);
end $body$;

revoke all on function public.dydem_reminder_admin_settings() from public,anon;
revoke all on function public.dydem_set_reminder_config(boolean,text,text) from public,anon;
revoke all on function public.dydem_set_user_reminders(uuid,boolean) from public,anon;
grant execute on function public.dydem_reminder_admin_settings() to authenticated;
grant execute on function public.dydem_set_reminder_config(boolean,text,text) to authenticated;
grant execute on function public.dydem_set_user_reminders(uuid,boolean) to authenticated;

-- Acción disponible: evita pedir una aprobación que todavía está bloqueada
-- por los pasos anteriores, y evita enviar correos al que ya aprobó.
create or replace function dydem_internal.reminder_pending_items()
returns table(user_id uuid,email text,name text,items_count bigint,items_html text)
language sql stable security definer set search_path=public,pg_temp as $body$
 select p.id,p.email,coalesce(nullif(p.display_name,''),p.email) as name,
 count(*)::bigint as items_count,
 string_agg(
   format('<li><a href="https://maxivisionmedia-sudo.github.io/dydem-web/#activity-%s">%s · %s</a> — %s</li>',
     a.id,
     replace(replace(replace(a.annex,'&','&amp;'),'<','&lt;'),'>','&gt;'),
     replace(replace(replace(left(coalesce(a.data->>'title','Actividad'),150),'&','&amp;'),'<','&lt;'),'>','&gt;'),
     stage.stage_name
   ),'' order by a.annex,stage.stage_number
 ) as items_html
 from public.profiles p
 join public.activities a on a.deleted_at is null
 cross join lateral (values
   ('review',1,'Revisión',coalesce((a.data->'steps'->>0)::boolean,false)),
   ('authorization',2,'Autorización',coalesce((a.data->'steps'->>1)::boolean,false)),
   ('verification',4,'Verificación',coalesce((a.data->'steps'->>2)::boolean,false)
                              and coalesce((a.data->'steps'->>3)::boolean,false))
 ) stage(stage_key,stage_number,stage_name,ready)
 where p.active and p.approval_reminders_enabled
  and p.email ~* '^[^@ ]+@[^@ ]+\.[^@ ]+$'
  and stage.ready
  and (a.data->'responsibles'->stage.stage_key) @> jsonb_build_array(p.id::text)
  and not (a.data->'approvals'->stage.stage_key) @> jsonb_build_array(p.id::text)
 group by p.id,p.email,p.display_name;
$body$;
revoke all on function dydem_internal.reminder_pending_items() from public,anon,authenticated;

create or replace function dydem_internal.refresh_reminder_delivery_status()
returns integer language plpgsql security definer set search_path=public,pg_temp as $body$
declare affected integer;
begin
 update dydem_internal.reminder_log l set
   status=case when coalesce(r.status_code,0) between 200 and 299 then 'accepted' else 'failed' end,
   last_error=case when coalesce(r.status_code,0) between 200 and 299 then null
     else left(coalesce(r.error_msg,case when r.timed_out then 'Tiempo de espera agotado'
     else 'HTTP '||coalesce(r.status_code::text,'sin respuesta') end),300) end,
   updated_at=now()
 from net._http_response r
 where l.status='queued' and l.request_id=r.id;
 get diagnostics affected=row_count;
 return affected;
end $body$;
revoke all on function dydem_internal.refresh_reminder_delivery_status() from public,anon,authenticated;

create or replace function dydem_internal.dispatch_due_reminders()
returns integer language plpgsql security definer set search_path=public,pg_temp as $body$
declare cfg dydem_internal.reminder_config%rowtype;
 v_api_key text;v_date date;v_hour integer;v_total integer:=0;
 v_request_id bigint;v_log_id bigint;
 recipient record;v_subject text;v_html text;
begin
 perform pg_advisory_xact_lock(7192026, 1);
 perform dydem_internal.refresh_reminder_delivery_status();
 select * into cfg from dydem_internal.reminder_config where id=1;
 if not cfg.enabled or cfg.resend_key_id is null or cfg.from_address='' then return 0;end if;
 v_date:=(now() at time zone 'America/Mexico_City')::date;
 v_hour:=extract(hour from now() at time zone 'America/Mexico_City')::integer;
 if v_hour<8 or v_hour>20 then return 0;end if;
 select decrypted_secret into v_api_key from vault.decrypted_secrets where id=cfg.resend_key_id;
 if v_api_key is null then return 0;end if;
 for recipient in select * from dydem_internal.reminder_pending_items() loop
   v_log_id:=null;
   insert into dydem_internal.reminder_log(user_id,reminder_date,items_count,status,attempts)
    values(recipient.user_id,v_date,recipient.items_count,'queued',1)
   on conflict(user_id,reminder_date) do update
    set status='queued',request_id=null,
        items_count=excluded.items_count,attempts=dydem_internal.reminder_log.attempts+1,
        last_error=null,updated_at=now()
    where dydem_internal.reminder_log.status='failed' and dydem_internal.reminder_log.attempts<3
   returning id into v_log_id;
   if v_log_id is null then continue;end if;
   v_subject:='DYDEM · '||recipient.items_count::text||
      case when recipient.items_count=1 then ' aprobación pendiente' else ' aprobaciones pendientes' end;
   v_html:='<html><body style="font-family:Arial,sans-serif;color:#23344d">'
    ||'<h2>Recordatorio de aprobaciones pendientes</h2>'
    ||'<p>Hola, '||replace(replace(replace(recipient.name,'&','&amp;'),'<','&lt;'),'>','&gt;')||'.</p>'
    ||'<p>Tienes confirmaciones de DYDEM pendientes de tu aprobación:</p><ul>'
    ||recipient.items_html||'</ul><p>Selecciona una actividad para abrirla y confirmar la etapa correspondiente.</p>'
    ||'<p style="font-size:12px;color:#64748b">Aviso automático diario de DYDEM.'
    ||' El Administrador puede desactivar estos correos.</p></body></html>';
   begin
    select net.http_post(
      url=>'https://api.resend.com/emails',
      headers=>jsonb_build_object('Authorization','Bearer '||v_api_key,
         'Content-Type','application/json'),
      body=>jsonb_build_object('from','DYDEM <'||cfg.from_address||'>',
          'to',jsonb_build_array(recipient.email),
          'subject',v_subject,'html',v_html),
      timeout_milliseconds=>10000
    ) into v_request_id;
    update dydem_internal.reminder_log set request_id=v_request_id,
      updated_at=now() where id=v_log_id;
    v_total:=v_total+1;
   exception when others then
    update dydem_internal.reminder_log set status='failed',
      last_error=left(SQLERRM,300),updated_at=now() where id=v_log_id;
   end;
 end loop;
 return v_total;
end $body$;
revoke all on function dydem_internal.dispatch_due_reminders() from public,anon,authenticated;

-- Una ejecución por hora. El dispatcher solo envía después de las 08:00
-- de CDMX y jamás repite un envío aceptado al mismo usuario en el mismo día.
select cron.schedule(
  'dydem_approval_reminders_hourly',
  '0 * * * *',
  'select dydem_internal.dispatch_due_reminders();'
);
