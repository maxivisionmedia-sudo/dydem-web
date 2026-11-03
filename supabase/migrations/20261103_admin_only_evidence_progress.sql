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
   'reviewers','','reviewAnnex','','authorizer','','progress',0,'evidenceProgress',0,'verification',0,
   'attachments','[]'::jsonb,'completedDate','','workCompletedDate','','responsibles','{"review":[],"authorization":[],"verification":[]}'::jsonb,'approvals','{"review":[],"authorization":[],"verification":[]}'::jsonb,'steps','[false,false,false,false,false,false,false]'::jsonb);
 perform public.validate_activity(v_data,v_id,v_annex);
 update public.activities set data=v_data where id=v_id;
 insert into public.activity_history(activity_id,changed_by,action,new_data)
 values(v_id,auth.uid(),'create',v_data);
 return jsonb_build_object('id',v_id,'data',v_data,'revision',1);
end $function$
;

CREATE OR REPLACE FUNCTION public.validate_activity(p_data jsonb, p_id bigint, p_annex text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare stage text; u text;
begin
 if jsonb_typeof(p_data)<>'object' then raise exception 'Datos de actividad inválidos';end if;
 if nullif(btrim(p_data->>'title'),'') is null then raise exception 'La descripción es obligatoria';end if;
 if (p_data->>'id')::bigint is distinct from p_id then raise exception 'No puedes cambiar el identificador';end if;
 if p_data->>'annex' is distinct from p_annex then raise exception 'No puedes cambiar el anexo';end if;
 if jsonb_typeof(p_data->'steps')<>'array' or jsonb_array_length(p_data->'steps')<>7 then raise exception 'Se requieren siete etapas';end if;
 if exists(select 1 from jsonb_array_elements(p_data->'steps') as s(value) where jsonb_typeof(s.value)<>'boolean') then
  raise exception 'Estado de etapas inválido';
 end if;
 if jsonb_typeof(p_data->'attachments')<>'array' then raise exception 'Formato de archivos inválido';end if;
 if coalesce((p_data->>'progress')::numeric,-1) not between 0 and 100 then raise exception 'Avance de obra fuera de rango';end if;
 if jsonb_typeof(p_data->'evidenceProgress')<>'number'
 or (p_data->>'evidenceProgress')::numeric not between 0 and 100 then
  raise exception 'Porcentaje de Evidencia inválido; se requiere un número entre 0 y 100';
 end if;
 if coalesce((p_data->>'verification')::numeric,-1) not between 0 and 100 then raise exception 'Dato interno de verificación inválido';end if;
 if coalesce(p_data->>'start','')<>'' and coalesce(p_data->>'end','')<>'' and (p_data->>'end')<(p_data->>'start') then
  raise exception 'La fecha final no puede ser anterior a la inicial';
 end if;
 if coalesce(p_data->>'workCompletedDate','')<>'' and (p_data->>'workCompletedDate')!~'^\d{4}-\d{2}-\d{2}$' then
  raise exception 'Fecha de fin de obra inválida';
 end if;
 for stage in select unnest(array['review','authorization','verification']) loop
  if jsonb_typeof(p_data->'responsibles'->stage)<>'array' or jsonb_typeof(p_data->'approvals'->stage)<>'array' then
    raise exception 'Faltan responsables o aprobaciones de %',stage;
  end if;
  if jsonb_array_length(p_data->'responsibles'->stage)>50 then raise exception 'Demasiados responsables';end if;
  if exists(select 1 from jsonb_array_elements(p_data->'responsibles'->stage) elem(v) where jsonb_typeof(elem.v)<>'string')
  or exists(select 1 from jsonb_array_elements(p_data->'approvals'->stage) elem(v) where jsonb_typeof(elem.v)<>'string') then
    raise exception 'Identificadores de responsables inválidos';
  end if;
  if exists(select 1 from jsonb_array_elements_text(p_data->'responsibles'->stage) elem(id) where id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
  or exists(select 1 from jsonb_array_elements_text(p_data->'approvals'->stage) elem(id) where id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'Formato de usuario inválido';
  end if;
  if (select count(*) from jsonb_array_elements_text(p_data->'responsibles'->stage)) <>
     (select count(distinct id) from jsonb_array_elements_text(p_data->'responsibles'->stage) elem(id))
  or (select count(*) from jsonb_array_elements_text(p_data->'approvals'->stage)) <>
     (select count(distinct id) from jsonb_array_elements_text(p_data->'approvals'->stage) elem(id)) then
    raise exception 'Responsables o aprobaciones repetidos';
  end if;
  if exists (select 1 from jsonb_array_elements_text(p_data->'approvals'->stage) a(id)
     where not exists(select 1 from jsonb_array_elements_text(p_data->'responsibles'->stage) r(id) where r.id=a.id)) then
    raise exception 'Solo los responsables pueden aprobar';
  end if;
  if exists(select 1 from jsonb_array_elements_text(p_data->'responsibles'->stage) x(id)
   where not exists(select 1 from public.profiles p where p.id=x.id::uuid and p.active)) then
    raise exception 'Los responsables deben ser usuarios activos de DYDEM';
  end if;
 end loop;
 if p_data->'steps' is distinct from (public.dydem_recompute_stages(p_data)->'steps') then
  raise exception 'El estado de las etapas no coincide con las aprobaciones registradas';
 end if;
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
 v_key text; v_stage text; v_n int; v_rev int; i int; v_norm jsonb;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and active and role='custom') then
  raise exception 'Solo un usuario personalizado activo puede usar esta operación' using errcode='42501';
 end if;
 select * into v_record from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada'; end if;
 if v_record.revision<>p_expected_revision then
  raise exception 'CONFLICTO_DE_VERSION: actualiza antes de guardar' using errcode='40001';
 end if;
 if p_data->'responsibles' is distinct from v_record.data->'responsibles'
 or p_data->'approvals' is distinct from v_record.data->'approvals'
 or p_data->'evidenceProgress' is distinct from v_record.data->'evidenceProgress'
 or p_data->>'reviewers' is distinct from v_record.data->>'reviewers'
 or p_data->>'reviewAnnex' is distinct from v_record.data->>'reviewAnnex'
 or p_data->>'authorizer' is distinct from v_record.data->>'authorizer'
 or p_data->>'verification' is distinct from v_record.data->>'verification' then
 raise exception 'Las aprobaciones se gestionan únicamente desde los controles de responsables' using errcode='42501';
end if;
for i in select * from unnest(array[1,2,4,5]) loop
 if p_data->'steps'->i is distinct from v_record.data->'steps'->i then
  raise exception 'Las etapas de aprobación y Evidencia se completan automáticamente' using errcode='42501';
 end if;
end loop;
v_norm:=public.dydem_recompute_stages(p_data);
perform public.validate_activity(v_norm,p_id,v_record.annex);
 -- Never let a stale activity update overwrite links to files already registered.
 -- Only attach_activity_file and remove_activity_file can alter attachment metadata.
 if p_data->'attachments' is distinct from v_record.data->'attachments' then
   raise exception 'DOCUMENTADO_PROTEGIDO: los anexos deben modificarse mediante el registro individual de archivos.' using errcode='23514';
 end if;
 if v_norm = v_record.data then
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
      if v_n=5 then
       raise exception 'El estado de Documentado se administra al añadir o eliminar archivos' using errcode='42501';
      end if;
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
    when v_key='workCompletedDate' then 'step3'
    when v_key='attachments' then 'step5'
    when v_key='completedDate' then 'step6'
    else null end;
   if v_key in ('responsibles','approvals','reviewers','reviewAnnex','authorizer','verification') or v_stage is null or not public.dydem_can(v_stage) then
    raise exception 'No tienes permiso para cambiar el campo %',v_key using errcode='42501';
   end if;
  end if;
 end loop;
 v_rev:=v_record.revision+1;
 update public.activities set data=v_norm,revision=v_rev,updated_at=now(),updated_by=auth.uid()
 where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values (p_id,auth.uid(),'update',v_record.data,v_norm);
 return jsonb_build_object('id',p_id,'data',v_norm,'revision',v_rev);
end $function$
;


do $initialize_evidence$
declare a public.activities%rowtype;d jsonb;
begin
 for a in select * from public.activities where not (data ? 'evidenceProgress') for update loop
  d:=jsonb_set(a.data,'{evidenceProgress}','0'::jsonb,true);
  update public.activities set data=d,revision=revision+1,updated_at=now() where id=a.id;
  insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
  values(a.id,null,'update',a.data,d);
 end loop;
end $initialize_evidence$;
