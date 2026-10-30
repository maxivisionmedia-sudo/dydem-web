
-- DYDEM. Tres roles: admin (total), viewer (lectura + comentarios) y custom (permisos granulares).
alter table public.profiles add column if not exists permissions jsonb not null default '{"steps":[false,false,false,false,false,false,false],"add":false,"delete":false}'::jsonb;
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('admin','viewer','custom'));
alter table public.profiles drop constraint if exists dydem_custom_permission_shape;
alter table public.profiles add constraint dydem_custom_permission_shape check (
 jsonb_typeof(permissions)='object'
 and jsonb_typeof(permissions->'steps')='array'
 and jsonb_array_length(permissions->'steps')=7
 and jsonb_typeof(permissions->'add')='boolean'
 and jsonb_typeof(permissions->'delete')='boolean'
 and jsonb_typeof(permissions->'steps'->0)='boolean'
 and jsonb_typeof(permissions->'steps'->1)='boolean'
 and jsonb_typeof(permissions->'steps'->2)='boolean'
 and jsonb_typeof(permissions->'steps'->3)='boolean'
 and jsonb_typeof(permissions->'steps'->4)='boolean'
 and jsonb_typeof(permissions->'steps'->5)='boolean'
 and jsonb_typeof(permissions->'steps'->6)='boolean'
);
create or replace function public.dydem_can(p_permission text) returns boolean
 language sql stable security definer set search_path=public,pg_temp as $role$
 select exists(
  select 1 from public.profiles
   where id=auth.uid() and active and (
     role='admin' or (role='custom' and (
       case
        when p_permission in ('add','delete') then permissions->>p_permission='true'
        when p_permission ~ '^step[0-6]$' then permissions->'steps'->((right(p_permission,1))::int)='true'::jsonb
        else false
       end
     ))
   )
 )
 $role$;
revoke all on function public.dydem_can(text) from public,anon;
grant execute on function public.dydem_can(text) to authenticated;

-- Las RPC existentes mantienen intactos los contadores, historial, revisión y reglas de eliminación.
CREATE OR REPLACE FUNCTION public.create_activity(p_title text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_start date; v_week int; v_code text; v_seq int; v_annex text; v_id bigint; v_data jsonb;
begin
 if not public.dydem_can('add') then raise exception 'Acceso denegado' using errcode='42501'; end if;
 if trim(coalesce(p_title,''))='' or length(p_title)>1000 then raise exception 'Descripción no válida'; end if;
 perform pg_advisory_xact_lock(7112026);
 v_start:=date_trunc('week',now() at time zone 'America/Mexico_City')::date;
 v_week:=to_char(v_start,'IW')::integer;
 v_code:=to_char(v_start,'IYYY')||'-S'||to_char(v_start,'IW');
 insert into public.annex_counters(week_code,last_used) values(v_code,1)
 on conflict(week_code) do update set last_used=public.annex_counters.last_used+1
 returning last_used into v_seq;
 v_annex:=v_week::text||'_'||v_seq::text;
 insert into public.activities(data,annex,updated_by) values('{}'::jsonb,v_annex,auth.uid()) returning id into v_id;
 v_data:=jsonb_build_object('id',v_id,'title',trim(p_title),'annex',v_annex,
   'weekCode',v_code,'weekNumber',v_week,'weekStart',to_char(v_start,'YYYY-MM-DD'),
   'weekEnd',to_char(v_start+6,'YYYY-MM-DD'),'start','','end','','before','','after','',
   'reviewers','','reviewAnnex','','authorizer','','progress',0,'verification',0,
   'attachments','[]'::jsonb,'completedDate','','steps','[false,false,false,false,false,false,false]'::jsonb);
 perform public.validate_activity(v_data,v_id,v_annex);
 update public.activities set data=v_data where id=v_id;
 insert into public.activity_history(activity_id,changed_by,action,new_data)
 values(v_id,auth.uid(),'create',v_data);
 return jsonb_build_object('id',v_id,'data',v_data,'revision',1);
end $function$
;
CREATE OR REPLACE FUNCTION public.delete_activity(p_id bigint, p_expected_revision integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activities%rowtype; v_other record; v_data jsonb;
begin
 if not public.dydem_can('delete') then raise exception 'Acceso denegado' using errcode='42501'; end if;
 select * into v_record from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada'; end if;
 if v_record.revision<>p_expected_revision then raise exception 'CONFLICTO_DE_VERSION: actualiza el cronograma e inténtalo otra vez' using errcode='40001'; end if;
 update public.activities set deleted_at=now(),revision=revision+1,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data)
 values(p_id,auth.uid(),'delete',v_record.data);
 -- Limpiar dependencias sin borrarlas de otras actividades.
 for v_other in select id,data from public.activities where deleted_at is null and
    (data->>'before'=p_id::text or data->>'after'=p_id::text) for update loop
   v_data:=v_other.data;
   if v_data->>'before'=p_id::text then v_data:=jsonb_set(v_data,'{before}','""'::jsonb); end if;
   if v_data->>'after'=p_id::text then v_data:=jsonb_set(v_data,'{after}','""'::jsonb); end if;
   update public.activities set data=v_data,revision=revision+1,updated_at=now(),updated_by=auth.uid() where id=v_other.id;
   insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
   values(v_other.id,auth.uid(),'update',v_other.data,v_data);
 end loop;
 return true;
end $function$
;

-- Edición parcial: se rechaza cualquier modificación de campos/etapas no concedidas.
create or replace function public.update_activity_custom(p_id bigint,p_expected_revision integer,p_data jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $custom$
declare
 v_record public.activities%rowtype;
 v_key text; v_stage text; v_n int; v_rev int;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and active and role='custom') then
  raise exception 'Solo un usuario personalizado activo puede usar esta operación' using errcode='42501';
 end if;
 select * into v_record from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada'; end if;
 if v_record.revision<>p_expected_revision then
  raise exception 'CONFLICTO_DE_VERSION: actualiza antes de guardar' using errcode='40001';
 end if;
 perform public.validate_activity(p_data,p_id,v_record.annex);
 if p_data = v_record.data then
  return jsonb_build_object('id',p_id,'data',v_record.data,'revision',v_record.revision);
 end if;
 for v_key in
   select k from
    (select jsonb_object_keys(v_record.data) as k
     union select jsonb_object_keys(p_data) as k) joined
   where (v_record.data->k) is distinct from (p_data->k)
 loop
  if v_key='steps' then
   for v_n in 0..6 loop
    if (p_data->'steps'->v_n) is distinct from (v_record.data->'steps'->v_n) then
      if not public.dydem_can('step'||v_n::text) then
       raise exception 'No tienes permiso para cambiar la etapa %',v_n+1 using errcode='42501';
      end if;
    end if;
   end loop;
  else
   v_stage := case
    when v_key in ('title','start','end','before','after') then 'step0'
    when v_key in ('reviewers','reviewAnnex') then 'step1'
    when v_key='authorizer' then 'step2'
    when v_key='progress' then 'step3'
    when v_key='verification' then 'step4'
    when v_key='attachments' then 'step5'
    when v_key='completedDate' then 'step6'
    else null end;
   if v_stage is null or not public.dydem_can(v_stage) then
    raise exception 'No tienes permiso para cambiar el campo %',v_key using errcode='42501';
   end if;
  end if;
 end loop;
 v_rev:=v_record.revision+1;
 update public.activities set data=p_data,revision=v_rev,updated_at=now(),updated_by=auth.uid()
 where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values (p_id,auth.uid(),'update',v_record.data,p_data);
 return jsonb_build_object('id',p_id,'data',p_data,'revision',v_rev);
end $custom$;
revoke all on function public.update_activity_custom(bigint,integer,jsonb) from public,anon;
grant execute on function public.update_activity_custom(bigint,integer,jsonb) to authenticated;

-- Los anexos de Documentado requieren permiso 6 y no permiten acceder a otras obras.
drop policy if exists dydem_attachments_upload on storage.objects;
create policy dydem_attachments_upload on storage.objects
for insert to authenticated with check (
 bucket_id='activity-attachments'
 and public.dydem_can('step5')
 and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
);
drop policy if exists dydem_attachments_delete on storage.objects;
create policy dydem_attachments_delete on storage.objects
for delete to authenticated using (
 bucket_id='activity-attachments'
 and public.dydem_can('step5')
 and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
);
