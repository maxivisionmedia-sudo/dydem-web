CREATE OR REPLACE FUNCTION public.update_activity(p_id bigint, p_expected_revision integer, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activities%rowtype; v_next int;
begin
 if not public.is_dydem_admin() then raise exception 'Acceso denegado' using errcode='42501'; end if;
 select * into v_record from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada'; end if;
 if v_record.revision<>p_expected_revision then
   raise exception 'CONFLICTO_DE_VERSION: otro usuario modificó esta actividad. Actualiza antes de guardar.' using errcode='40001';
 end if;
 perform public.validate_activity(p_data,p_id,v_record.annex);
 -- Never let a stale activity update overwrite links to files already registered.
 -- Only attach_activity_file and remove_activity_file can alter attachment metadata.
 if p_data->'attachments' is distinct from v_record.data->'attachments' then
   raise exception 'DOCUMENTADO_PROTEGIDO: los anexos deben modificarse mediante el registro individual de archivos.' using errcode='23514';
 end if;
 -- El ID, anexo, semana de alta y contador son inmutables desde el navegador.
 if p_data->>'weekCode' is distinct from v_record.data->>'weekCode'
    or p_data->>'weekStart' is distinct from v_record.data->>'weekStart'
    or p_data->>'weekEnd' is distinct from v_record.data->>'weekEnd'
    or p_data->>'weekNumber' is distinct from v_record.data->>'weekNumber' then
   raise exception 'La semana original de alta no puede modificarse';
 end if;
 v_next:=v_record.revision+1;
 update public.activities set data=p_data,revision=v_next,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(p_id,auth.uid(),'update',v_record.data,p_data);
 return jsonb_build_object('id',p_id,'data',p_data,'revision',v_next);
end $function$
;

CREATE OR REPLACE FUNCTION public.update_activity_custom(p_id bigint, p_expected_revision integer, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
 -- Never let a stale activity update overwrite links to files already registered.
 -- Only attach_activity_file and remove_activity_file can alter attachment metadata.
 if p_data->'attachments' is distinct from v_record.data->'attachments' then
   raise exception 'DOCUMENTADO_PROTEGIDO: los anexos deben modificarse mediante el registro individual de archivos.' using errcode='23514';
 end if;
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
end $function$
;


create or replace function public.remove_activity_file(p_activity_id bigint,p_file_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $remove$
declare
 v_activity public.activities%rowtype;
 v_file jsonb;
 v_after jsonb;
 v_next jsonb;
 v_revision integer;
begin
 if auth.uid() is null or not public.dydem_can('step5') then
  raise exception 'No tienes permiso para quitar anexos' using errcode='42501';
 end if;
 select * into v_activity from public.activities
 where id=p_activity_id and project_id='00000000-0000-4000-8000-00000000d1de'
 and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada';end if;
 select file into v_file from jsonb_array_elements(coalesce(v_activity.data->'attachments','[]'::jsonb)) file
 where file->>'id'=p_file_id limit 1;
 if v_file is null then
  return jsonb_build_object('id',p_activity_id,'revision',v_activity.revision,'data',v_activity.data,'already_removed',true);
 end if;
 select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_after
 from jsonb_array_elements(v_activity.data->'attachments') with ordinality as elem(value,ordinality)
 where value->>'id' is distinct from p_file_id;
 v_next:=jsonb_set(v_activity.data,'{attachments}',v_after);
 if jsonb_array_length(v_after)=0 then
  v_next:=jsonb_set(v_next,'{steps,5}','false'::jsonb,false);
 end if;
 perform public.validate_activity(v_next,p_activity_id,v_activity.annex);
 v_revision:=v_activity.revision+1;
 update public.activities set data=v_next,revision=v_revision,updated_at=now(),updated_by=auth.uid()
 where id=p_activity_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(p_activity_id,auth.uid(),'update',v_activity.data,v_next);
 return jsonb_build_object('id',p_activity_id,'revision',v_revision,'data',v_next,'removed_file',v_file);
end $remove$;
revoke all on function public.remove_activity_file(bigint,text) from public,anon;
grant execute on function public.remove_activity_file(bigint,text) to authenticated;
