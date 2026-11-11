
-- DYDEM: retirada segura de usuarios, conservando historial y nombre en login.
alter table public.profiles
 add column if not exists removed_at timestamptz,
 add column if not exists last_login_at timestamptz;
create index if not exists dydem_profiles_removed_at_idx on public.profiles(removed_at) where removed_at is not null;

create or replace function public.dydem_register_login()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $body$
declare p public.profiles%rowtype; suggested_name text;
begin
 if auth.uid() is null then raise exception 'Sesión requerida' using errcode='42501';end if;
 select * into p from public.profiles where id=auth.uid() for update;
 if not found or not p.active or p.removed_at is not null then
  raise exception 'Esta cuenta no tiene acceso activo a DYDEM' using errcode='42501';
 end if;
 if nullif(btrim(p.display_name),'') is null then
  select left(btrim(coalesce(nullif(raw_user_meta_data->>'display_name',''),
    nullif(raw_user_meta_data->>'full_name',''),split_part(p.email,'@',1))),120)
   into suggested_name from auth.users where id=p.id;
  if suggested_name is null or suggested_name='' then
   suggested_name:=left(split_part(p.email,'@',1),120);
  end if;
  update public.profiles set display_name=suggested_name,last_login_at=now()
    where id=p.id returning * into p;
 else
  update public.profiles set last_login_at=now()
    where id=p.id returning * into p;
 end if;
 return jsonb_build_object('id',p.id,'display_name',p.display_name,'last_login_at',p.last_login_at);
end $body$;

create or replace function public.dydem_remove_user(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $body$
declare target public.profiles%rowtype; remaining_admins integer;pending_count integer;
 pending_detail text;
begin
 if auth.uid() is null or not public.is_dydem_admin() then
  raise exception 'Solo un Administrador puede remover usuarios' using errcode='42501';
 end if;
 if p_user_id is null then raise exception 'Selecciona un usuario válido';end if;
 if p_user_id=auth.uid() then
  raise exception 'No puedes remover tu propia cuenta de Administrador';
 end if;
 select * into target from public.profiles where id=p_user_id for update;
 if not found then raise exception 'El usuario no existe';end if;
 if target.removed_at is not null then
  return jsonb_build_object('ok',true,'already_removed',true,'id',p_user_id);
 end if;
 if target.active and target.role='admin' then
  select count(*) into remaining_admins
   from public.profiles where active and role='admin' and removed_at is null;
  if remaining_admins<=1 then
   raise exception 'Debe quedar al menos un Administrador activo';
  end if;
 end if;
 -- No eliminar asignaciones ni votos de forma automática: un pendiente
 -- debe reasignarse primero, conservando el historial de aprobaciones.
 select count(*),left(string_agg(
   coalesce(nullif(btrim(a.annex),''),a.id::text)||' ('||st.name||')',
   ', ' order by a.id,st.name),250)
 into pending_count,pending_detail
 from public.activities a
 cross join lateral (values
    ('review','Revisión'),
    ('authorization','Autorización'),
    ('verification','Verificación')
 ) as st(key,name)
 where a.deleted_at is null
  and coalesce(a.data->'responsibles'->st.key,'[]'::jsonb) @> jsonb_build_array(p_user_id::text)
  and not coalesce(a.data->'approvals'->st.key,'[]'::jsonb) @> jsonb_build_array(p_user_id::text);
 if pending_count>0 then
  raise exception 'Este usuario tiene % aprobación(es) pendientes: %. Reasígnalas antes de removerlo.',
   pending_count,pending_detail;
 end if;
 update public.profiles set active=false,approval_reminders_enabled=false,removed_at=now()
 where id=p_user_id;
 return jsonb_build_object('ok',true,'id',p_user_id,'display_name',target.display_name,
   'history_preserved',true);
end $body$;

-- Read-only display of archived assigned users to preserve historical names;
-- eligible assignee lists continue to exclude inactive profiles.
create or replace function public.list_dydem_responsibles()
returns table(id uuid,display_name text)
language sql stable security definer set search_path=public,pg_temp as $body$
 select p.id,
  coalesce(nullif(btrim(p.display_name),''),split_part(p.email,'@',1))::text
 from public.profiles p
 where public.is_active_user()
  and (p.active or exists(
   select 1 from public.activities a
   where a.deleted_at is null and
    (coalesce(a.data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(p.id::text)
      or coalesce(a.data->'responsibles'->'authorization','[]'::jsonb) @> jsonb_build_array(p.id::text)
      or coalesce(a.data->'responsibles'->'verification','[]'::jsonb) @> jsonb_build_array(p.id::text))
  ))
 order by 2,1;
$body$;

CREATE OR REPLACE FUNCTION public.dydem_reminder_admin_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  ) order by p.display_name,p.email),'[]'::jsonb) from public.profiles p where p.removed_at is null),
  'delivery_summary',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from
    (select l.reminder_date,l.status,count(*) as total from dydem_internal.reminder_log l
      group by l.reminder_date,l.status order by l.reminder_date desc limit 12) x)
 );
end $function$
;
revoke all on function public.dydem_register_login() from public,anon;
revoke all on function public.dydem_remove_user(uuid) from public,anon;
grant execute on function public.dydem_register_login() to authenticated;
grant execute on function public.dydem_remove_user(uuid) to authenticated;
