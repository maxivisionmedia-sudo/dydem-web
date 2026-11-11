-- Mover archivos a Revisión; mantener historial y vínculos físicos en Supabase Storage.
-- Los archivos de Propuesta existentes se transfieren a reviewAttachments sin borrarlos.
-- Se mantiene el nombre interno proposal_upload_intents para no invalidar cargas antiguas.
alter table public.activity_comments
 add column if not exists attachment_refs jsonb not null default '[]'::jsonb;
alter table public.activity_comments
 add constraint dydem_dudas_review_file_refs_array check (jsonb_typeof(attachment_refs)='array');

update public.activities a
set data=jsonb_set(
 jsonb_set(
   jsonb_set(a.data,'{reviewAttachments}',
     coalesce(a.data->'reviewAttachments',a.data->'proposalAttachments','[]'::jsonb),true),
   '{proposalAttachments}','[]'::jsonb,true),
 '{manualApprovals}',coalesce(a.data->'manualApprovals',
  '{"review":false,"authorization":false,"verification":false}'::jsonb),true)
where a.project_id='00000000-0000-4000-8000-00000000d1de'::uuid and a.deleted_at is null;
-- Note: no bytes are removed from Storage.

create or replace function public.dydem_can_review_file(p_activity_id bigint,p_action text)
returns boolean language plpgsql stable security definer
set search_path=public,pg_temp as $body$
declare v_data jsonb;
begin
 if auth.uid() is null or not public.is_active_user()
    or p_action not in ('add','delete') then return false;end if;
 select data into v_data from public.activities where id=p_activity_id
  and project_id='00000000-0000-4000-8000-00000000d1de'::uuid
  and deleted_at is null;
 if not found then return false;end if;
 if public.is_dydem_admin() then return true;end if;
 if coalesce((v_data->'steps'->>1)::boolean,false) or not coalesce((v_data->'steps'->>0)::boolean,false) then
  return false;end if;
 return public.dydem_can(case when p_action='add' then 'doc_add' else 'doc_delete' end)
 or coalesce(v_data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(auth.uid()::text);
end $body$;
revoke all on function public.dydem_can_review_file(bigint,text) from public,anon;
grant execute on function public.dydem_can_review_file(bigint,text) to authenticated;
create or replace function public.dydem_review_storage_path(p_path text,p_action text)
returns boolean language plpgsql stable security definer
set search_path=public,pg_temp as $body$
declare v_activity bigint;
begin
 select activity_id into v_activity from public.proposal_upload_intents
 where storage_path=p_path and (p_action='delete' or uploaded_by=auth.uid())
 limit 1;
 if not found then return false;end if;
 return public.dydem_can_review_file(v_activity,p_action);
end $body$;
revoke all on function public.dydem_review_storage_path(text,text) from public,anon;
grant execute on function public.dydem_review_storage_path(text,text) to authenticated;
CREATE OR REPLACE FUNCTION public.dydem_recompute_stages(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d jsonb:=p_data;st jsonb; k text; i integer; count_assigned integer;votes integer; all_signed boolean;
begin
 if jsonb_typeof(d)<>'object' or jsonb_typeof(d->'steps')<>'array' or jsonb_array_length(d->'steps')<>7 then raise exception 'Actividad inválida';end if;
 st:=d->'steps';
 for k,i in select * from (values ('review',1),('authorization',2),('verification',4)) as x(k,i) loop
  if jsonb_typeof(d->'responsibles'->k)<>'array' or jsonb_typeof(d->'approvals'->k)<>'array' then raise exception 'Responsables inválidos: %',k;end if;
  count_assigned:=jsonb_array_length(d->'responsibles'->k);
  votes:=jsonb_array_length(d->'approvals'->k);
  all_signed:=(count_assigned>0 and votes=count_assigned
    and not exists(select 1 from jsonb_array_elements_text(d->'responsibles'->k) as u(id)
                   where not exists(select 1 from jsonb_array_elements_text(d->'approvals'->k) as v(id) where v.id=u.id)))
    or (count_assigned=0 and coalesce((d->'manualApprovals'->>k)::boolean,false));
  if i=1 then st:=jsonb_set(st,'{1}',to_jsonb(all_signed and st->>0='true'),false);end if;
  if i=2 then st:=jsonb_set(st,'{2}',to_jsonb(all_signed and st->>1='true'),false);end if;
  if i=4 then
    st:=jsonb_set(st,'{3}',to_jsonb(coalesce((d->>'progress')::numeric,0)=100),false);
    st:=jsonb_set(st,'{4}',to_jsonb(all_signed and st->>2='true' and st->>3='true'),false);
  end if;
 end loop;
 st:=jsonb_set(st,'{5}',to_jsonb(st->>4='true' and jsonb_array_length(coalesce(d->'attachments','[]'::jsonb))>0),false);
 st:=jsonb_set(st,'{6}',to_jsonb(st->>6='true' and st->>0='true' and st->>1='true' and st->>2='true'
   and st->>3='true' and st->>4='true' and st->>5='true' and coalesce(d->>'completedDate','')<>''),false);
 return jsonb_set(d,'{steps}',st,false);
end $function$;

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
 if jsonb_typeof(p_data->'proposalAttachments')<>'array' then raise exception 'Formato histórico de Propuesta inválido';end if;
 if jsonb_typeof(p_data->'reviewAttachments')<>'array' then raise exception 'Los archivos de Revisión deben ser una lista';end if;
 if jsonb_typeof(p_data->'manualApprovals')<>'object'
  or exists(select 1 from jsonb_each(p_data->'manualApprovals') v(k,x) where jsonb_typeof(v.x)<>'boolean') then
  raise exception 'El formato de aprobaciones administrativas es inválido';end if;
 if jsonb_typeof(p_data->'proposalDescription')<>'string' or length(p_data->>'proposalDescription')>10000 then
  raise exception 'La descripción de Propuesta debe contener como máximo 10000 caracteres';end if;
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
end $function$;

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
   'attachments','[]'::jsonb,'proposalAttachments','[]'::jsonb,'reviewAttachments','[]'::jsonb,'manualApprovals','{"review":false,"authorization":false,"verification":false}'::jsonb,'proposalDescription','','completedDate','','workCompletedDate','','responsibles','{"review":[],"authorization":[],"verification":[]}'::jsonb,'approvals','{"review":[],"authorization":[],"verification":[]}'::jsonb,'steps','[false,false,false,false,false,false,false]'::jsonb);
 perform public.validate_activity(v_data,v_id,v_annex);
 update public.activities set data=v_data where id=v_id;
 insert into public.activity_history(activity_id,changed_by,action,new_data)
 values(v_id,auth.uid(),'create',v_data);
 return jsonb_build_object('id',v_id,'data',v_data,'revision',1);
end $function$;

CREATE OR REPLACE FUNCTION public.update_activity(p_id bigint, p_expected_revision integer, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activities%rowtype; v_next int; i int; v_norm jsonb;
begin
 if not public.is_dydem_admin() then raise exception 'Acceso denegado' using errcode='42501'; end if;
 select * into v_record from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada'; end if;
 if v_record.revision<>p_expected_revision then
   raise exception 'CONFLICTO_DE_VERSION: otro usuario modificó esta actividad. Actualiza antes de guardar.' using errcode='40001';
 end if;
 if p_data->'manualApprovals' is distinct from v_record.data->'manualApprovals' then
  raise exception 'Las aprobaciones administrativas se gestionan desde su control exclusivo' using errcode='42501';
 end if;
 if p_data->'responsibles' is distinct from v_record.data->'responsibles'
 or p_data->'approvals' is distinct from v_record.data->'approvals'
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
 if p_data->'reviewAttachments' is distinct from v_record.data->'reviewAttachments' then
   raise exception 'ARCHIVOS_REVISION_PROTEGIDOS: gestiona los archivos desde Revisión' using errcode='23514';
 end if;
 if p_data->'proposalAttachments' is distinct from v_record.data->'proposalAttachments' then
    raise exception 'PROPUESTA_PROTEGIDA: los archivos de Propuesta solo se gestionan por separado' using errcode='23514';
 end if;
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
 update public.activities set data=v_norm,revision=v_next,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(p_id,auth.uid(),'update',v_record.data,v_norm);
 return jsonb_build_object('id',p_id,'data',v_norm,'revision',v_next);
end $function$;

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
 if p_data->'manualApprovals' is distinct from v_record.data->'manualApprovals' then
  raise exception 'Las aprobaciones administrativas solo se gestionan por el servidor' using errcode='42501';
 end if;
 if p_data->'responsibles' is distinct from v_record.data->'responsibles'
 or p_data->'approvals' is distinct from v_record.data->'approvals'
 or p_data->'evidenceProgress' is distinct from v_record.data->'evidenceProgress'
 or p_data->'proposalDescription' is distinct from v_record.data->'proposalDescription'
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
 if p_data->'reviewAttachments' is distinct from v_record.data->'reviewAttachments' then
   raise exception 'ARCHIVOS_REVISION_PROTEGIDOS: gestiona los archivos desde Revisión' using errcode='23514';
 end if;
 if p_data->'proposalAttachments' is distinct from v_record.data->'proposalAttachments' then
    raise exception 'PROPUESTA_PROTEGIDA: los archivos de Propuesta solo se gestionan por separado' using errcode='23514';
 end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.set_activity_responsibles(p_id bigint, p_stage integer, p_users uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.activities%rowtype; d jsonb; k text; valid_users integer;assigned jsonb; n integer;
begin
 if auth.uid() is null or not public.is_active_user() then raise exception 'Sesión requerida' using errcode='42501';end if;
 if p_stage not in (1,2,4) then raise exception 'Etapa de aprobación no válida';end if;
 if not public.is_dydem_admin() then raise exception 'Solo el Administrador puede asignar o modificar los responsables' using errcode='42501';end if;
 if p_users is null or array_length(p_users,1)>50 then raise exception 'Selección inválida de usuarios';end if;
 if exists(select 1 from unnest(p_users) u where u is null) then raise exception 'Usuario inválido';end if;
 if (select count(*) from unnest(p_users)) is distinct from (select count(distinct u) from unnest(p_users) u) then
  raise exception 'No se permiten responsables duplicados';
 end if;
 if exists(select 1 from unnest(p_users) u where not exists(
    select 1 from public.profiles p where p.id=u and p.active
  )) then
  raise exception 'Solo puedes asignar usuarios activos de DYDEM';
 end if;
 k:=case p_stage when 1 then 'review' when 2 then 'authorization' else 'verification' end;
 select * into r from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no disponible';end if;
 select coalesce(jsonb_agg(u::text order by u::text),'[]'::jsonb) into assigned from unnest(p_users) u;
 if r.data->'responsibles'->k = assigned then
  return jsonb_build_object('id',p_id,'revision',r.revision,'data',r.data);
 end if;
 d:=jsonb_set(r.data,array['responsibles',k],assigned,false);
 d:=jsonb_set(d,array['approvals',k],'[]'::jsonb,false);
 d:=jsonb_set(d,array['manualApprovals',k],'false'::jsonb,true);
 d:=public.dydem_recompute_stages(d);
 perform public.validate_activity(d,p_id,r.annex);
 n:=r.revision+1;
 update public.activities set data=d,revision=n,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data) values(p_id,auth.uid(),'update',r.data,d);
 return jsonb_build_object('id',p_id,'revision',n,'data',d);
end $function$;

CREATE OR REPLACE FUNCTION public.vote_activity_stage(p_id bigint, p_stage integer, p_approved boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.activities%rowtype;d jsonb;k text;n integer;v jsonb;vote_id text;unassigned boolean;admin_user boolean;
begin
 if auth.uid() is null or not public.is_active_user() then raise exception 'Sesión requerida' using errcode='42501';end if;
 if p_stage not in (1,2,4) or p_approved is null then raise exception 'Aprobación inválida';end if;
 -- El único permiso para confirmar es estar asignado como responsable.
 -- La cuenta debe estar activa y cada voto se vincula a auth.uid().
 k:=case p_stage when 1 then 'review' when 2 then 'authorization' else 'verification' end;
 select * into r from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada';end if;
 vote_id:=auth.uid()::text;
 admin_user:=public.is_dydem_admin();
 unassigned:=jsonb_array_length(r.data->'responsibles'->k)=0;
 if not admin_user and coalesce((r.data->'steps'->>p_stage)::boolean,false) then
  raise exception 'La etapa ya terminó: su confirmación está bloqueada' using errcode='42501';
 end if;
 if unassigned then
  if not admin_user then
   raise exception 'Solo el Administrador puede confirmar una etapa sin responsables' using errcode='42501';
  end if;
 elsif not exists(select 1 from jsonb_array_elements_text(r.data->'responsibles'->k) u(id) where u.id=vote_id) then
  raise exception 'Tu usuario no está asignado como responsable de esta etapa' using errcode='42501';
 end if;
 if p_approved and (
   (p_stage=1 and r.data->'steps'->>0<>'true')
   or (p_stage=2 and r.data->'steps'->>1<>'true')
   or (p_stage=4 and (r.data->'steps'->>2<>'true' or r.data->'steps'->>3<>'true'))
 ) then raise exception 'No se han completado los requisitos previos de esta aprobación';end if;
 if unassigned then
   if coalesce((r.data->'manualApprovals'->>k)::boolean,false)=p_approved then
    return jsonb_build_object('id',p_id,'revision',r.revision,'data',r.data);
   end if;
   d:=jsonb_set(r.data,array['manualApprovals',k],to_jsonb(p_approved),true);
 else
   select coalesce(jsonb_agg(x.id),'[]'::jsonb) into v
    from jsonb_array_elements_text(r.data->'approvals'->k) x(id) where x.id<>vote_id;
   if p_approved then v:=v||jsonb_build_array(vote_id);end if;
   if v=r.data->'approvals'->k then return jsonb_build_object('id',p_id,'revision',r.revision,'data',r.data);end if;
   d:=jsonb_set(r.data,array['approvals',k],v,false);
 end if;
 d:=public.dydem_recompute_stages(d);
 perform public.validate_activity(d,p_id,r.annex);
 n:=r.revision+1;
 update public.activities set data=d,revision=n,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data) values(p_id,auth.uid(),'update',r.data,d);
 return jsonb_build_object('id',p_id,'revision',n,'data',d);
end $function$;

CREATE OR REPLACE FUNCTION public.begin_review_upload(p_activity_id bigint, p_upload_id uuid, p_file_name text, p_storage_name text, p_file_size bigint, p_mime_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.proposal_upload_intents%rowtype;v_path text;v_mime text;
begin
 if auth.uid() is null or not public.dydem_can_review_file(p_activity_id,'add') then
  raise exception 'Solo Administrador puede subir archivos para Revisión' using errcode='42501';end if;
 if not exists(select 1 from public.activities where id=p_activity_id and project_id='00000000-0000-4000-8000-00000000d1de'::uuid and deleted_at is null) then
  raise exception 'Actividad no disponible';end if;
 if p_upload_id is null or p_file_size not between 1 and 524288000
  or p_file_name is null or length(btrim(p_file_name)) not between 1 and 255
  or p_storage_name is null or length(p_storage_name) not between 1 and 100
  or p_storage_name !~ '^[A-Za-z0-9._-]+$' or p_storage_name in ('.','..') then
  raise exception 'Archivo para Revisión inválido';end if;
 v_mime:=coalesce(nullif(left(p_mime_type,255),''),'application/octet-stream');
 v_path:='00000000-0000-4000-8000-00000000d1de/'||p_activity_id||'/'||p_upload_id||'/'||p_storage_name;
 insert into public.proposal_upload_intents
 (id,project_id,activity_id,uploaded_by,file_name,storage_name,file_size,mime_type,storage_path)
 values(p_upload_id,'00000000-0000-4000-8000-00000000d1de'::uuid,p_activity_id,auth.uid(),p_file_name,p_storage_name,p_file_size,v_mime,v_path)
 on conflict(id) do nothing;
 select * into v_record from public.proposal_upload_intents where id=p_upload_id for update;
 if v_record.uploaded_by is distinct from auth.uid()
 or v_record.activity_id is distinct from p_activity_id
 or v_record.file_name is distinct from p_file_name
 or v_record.file_size is distinct from p_file_size
 or v_record.storage_name is distinct from p_storage_name
 or v_record.mime_type is distinct from v_mime then
  raise exception 'Conflicto en el identificador de carga de Revisión' using errcode='42501';end if;
 return jsonb_build_object('id',v_record.id,'activity_id',v_record.activity_id,
 'name',v_record.file_name,'size',v_record.file_size,'type',v_record.mime_type,
 'path',v_record.storage_path,'status',v_record.status,'section','review');
end $function$;

CREATE OR REPLACE FUNCTION public.complete_review_upload(p_upload_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_intent public.proposal_upload_intents%rowtype;
 v_obj storage.objects%rowtype;v_activity public.activities%rowtype;
 v_data jsonb;v_meta jsonb;v_revision integer;v_existing boolean;
begin
 if auth.uid() is null or not public.is_active_user() then
  raise exception 'Sesión activa requerida' using errcode='42501';end if;
 select * into v_intent from public.proposal_upload_intents where id=p_upload_id for update;
 if not found or v_intent.uploaded_by is distinct from auth.uid() then
  raise exception 'Carga de Revisión no disponible' using errcode='42501';end if;
 if not public.dydem_can_review_file(v_intent.activity_id,'add') then
  raise exception 'La Revisión ya terminó o no tienes permiso para añadir archivos' using errcode='42501';end if;
 select * into v_activity from public.activities
 where id=v_intent.activity_id and project_id='00000000-0000-4000-8000-00000000d1de'::uuid and deleted_at is null
 for update;
 if not found then raise exception 'Actividad no disponible';end if;
 if v_intent.status='linked' then
  return jsonb_build_object('status','linked','already_linked',true,'id',v_activity.id,
   'data',v_activity.data,'revision',v_activity.revision);
 end if;
 select * into v_obj from storage.objects where bucket_id='activity-attachments'
 and name=v_intent.storage_path and owner_id=v_intent.uploaded_by::text;
 if not found then
  return jsonb_build_object('status','pending','id',v_activity.id,
   'name',v_intent.file_name,'message','El archivo todavía no está completo en Storage');
 end if;
 if coalesce((v_obj.metadata->>'size')::bigint,-1)<>v_intent.file_size then
  raise exception 'El archivo almacenado tiene un tamaño distinto al registrado';end if;
 select exists(select 1 from jsonb_array_elements(coalesce(v_activity.data->'reviewAttachments','[]'::jsonb)) elem
  where elem->>'id'=p_upload_id::text or elem->>'path'=v_intent.storage_path) into v_existing;
 if v_existing then
  update public.proposal_upload_intents set status='linked',linked_at=now() where id=p_upload_id;
  return jsonb_build_object('status','linked','already_linked',true,'id',v_activity.id,'data',v_activity.data,'revision',v_activity.revision);
 end if;
 v_meta:=jsonb_build_object('id',v_intent.id,'name',v_intent.file_name,
  'type',v_intent.mime_type,'size',v_intent.file_size,'path',v_intent.storage_path);
 v_data:=jsonb_set(v_activity.data,'{reviewAttachments}',
  coalesce(v_activity.data->'reviewAttachments','[]'::jsonb)||jsonb_build_array(v_meta),true);
 perform public.validate_activity(v_data,v_activity.id,v_activity.annex);
 v_revision:=v_activity.revision+1;
 update public.activities set data=v_data,revision=v_revision,updated_at=now(),updated_by=auth.uid()
 where id=v_activity.id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(v_activity.id,auth.uid(),'update',v_activity.data,v_data);
 update public.proposal_upload_intents set status='linked',linked_at=now() where id=p_upload_id;
 return jsonb_build_object('status','linked','already_linked',false,'id',v_activity.id,'data',v_data,'revision',v_revision);
end $function$;

CREATE OR REPLACE FUNCTION public.remove_review_file(p_activity_id bigint, p_file_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.activities%rowtype;v_file jsonb;v_after jsonb;v_next jsonb;v_rev integer;
begin
 if auth.uid() is null or not public.dydem_can_review_file(p_activity_id,'delete') then
  raise exception 'Solo Administrador puede eliminar archivos de Revisión' using errcode='42501';end if;
 select * into r from public.activities where id=p_activity_id and project_id='00000000-0000-4000-8000-00000000d1de'::uuid and deleted_at is null for update;
 if not found then raise exception 'Actividad no disponible';end if;
 select value into v_file from jsonb_array_elements(coalesce(r.data->'reviewAttachments','[]'::jsonb)) as elem(value)
  where value->>'id'=p_file_id limit 1;
 if v_file is null then return jsonb_build_object('id',r.id,'revision',r.revision,'data',r.data,'already_removed',true);end if;
 select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_after
 from jsonb_array_elements(r.data->'reviewAttachments') with ordinality as elem(value,ordinality)
 where value->>'id' is distinct from p_file_id;
 v_next:=jsonb_set(r.data,'{reviewAttachments}',v_after,false);
 perform public.validate_activity(v_next,r.id,r.annex);
 v_rev:=r.revision+1;
 update public.activities set data=v_next,revision=v_rev,updated_at=now(),updated_by=auth.uid() where id=r.id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(r.id,auth.uid(),'update',r.data,v_next);
 return jsonb_build_object('id',r.id,'revision',v_rev,'data',v_next,'removed_file',v_file);
end $function$;

CREATE OR REPLACE FUNCTION public.dydem_prepare_comment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_author text; v_data jsonb; v_refs jsonb;
begin
 if auth.uid() is null or not public.is_active_user() then
  raise exception 'Se requiere una cuenta activa de DYDEM' using errcode='42501';
 end if;
 if new.body is null or char_length(btrim(new.body)) not between 1 and 2000 then
  raise exception 'El comentario debe contener entre 1 y 2000 caracteres';
 end if;
 if not exists (
   select 1 from public.activities a
   where a.id=new.activity_id and a.project_id='00000000-0000-4000-8000-00000000d1de'
   and a.deleted_at is null
 ) then
  raise exception 'La actividad ya no está disponible para comentarios';
 end if;
 select a.data into v_data from public.activities a
 where a.id=new.activity_id and a.deleted_at is null;
 if new.thread='dudas' and coalesce((v_data->'steps'->>1)::boolean,false)
    and not public.is_dydem_admin() then
   raise exception 'La Revisión terminó: no puedes publicar nuevas dudas' using errcode='42501';
 end if;
 if new.thread='dudas' then
   if jsonb_typeof(coalesce(new.attachment_refs,'[]'::jsonb))<>'array'
    or jsonb_array_length(coalesce(new.attachment_refs,'[]'::jsonb))>15 then
      raise exception 'Selecciona como máximo 15 archivos de Revisión';end if;
   if exists(select 1 from jsonb_array_elements_text(coalesce(new.attachment_refs,'[]'::jsonb)) q(id)
     where not exists(select 1 from jsonb_array_elements(coalesce(v_data->'reviewAttachments','[]'::jsonb)) f(meta)
       where f.meta->>'id'=q.id)) then
      raise exception 'Una referencia de Dudas no corresponde a un archivo de esta Revisión';end if;
   new.attachment_refs:=coalesce(new.attachment_refs,'[]'::jsonb);
 else
   if coalesce(new.attachment_refs,'[]'::jsonb)<>'[]'::jsonb then
    raise exception 'Las referencias de archivo solo se permiten en Dudas';end if;
   new.attachment_refs:='[]'::jsonb;
 end if;
 select coalesce(nullif(p.display_name,''),nullif(p.email,''),'Usuario') into v_author
 from public.profiles p where p.id=auth.uid() and p.active;
 if v_author is null then
  raise exception 'No se encontró el usuario activo' using errcode='42501';
 end if;
 new.project_id := '00000000-0000-4000-8000-00000000d1de';
 new.author_id := auth.uid();
 new.author_name := v_author;
 new.body := btrim(new.body);
 new.created_at := now();
 return new;
end $function$;


-- Protect uploads after the review has closed, including direct Storage API writes.
drop policy if exists dydem_attachments_upload on storage.objects;
create policy dydem_attachments_upload on storage.objects for insert to authenticated
 with check (bucket_id='activity-attachments'
 and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
 and (
   (public.dydem_can('doc_add') and not exists(
      select 1 from public.proposal_upload_intents i where i.storage_path=name))
    or public.dydem_review_storage_path(name,'add')
 ));
drop policy if exists dydem_attachments_delete on storage.objects;
create policy dydem_attachments_delete on storage.objects for delete to authenticated
 using (bucket_id='activity-attachments'
 and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
 and (
   (public.dydem_can('doc_delete') and not exists(
     select 1 from public.proposal_upload_intents i where i.storage_path=name))
    or public.dydem_review_storage_path(name,'delete')
 ));
-- Remove old proposal RPCs: they must not remain callable.
drop function if exists public.begin_proposal_upload(bigint,uuid,text,text,bigint,text);
drop function if exists public.complete_proposal_upload(uuid);
drop function if exists public.remove_proposal_file(bigint,text);
revoke all on function public.begin_review_upload(bigint,uuid,text,text,bigint,text) from public,anon;
revoke all on function public.complete_review_upload(uuid) from public,anon;
revoke all on function public.remove_review_file(bigint,text) from public,anon;
grant execute on function public.begin_review_upload(bigint,uuid,text,text,bigint,text) to authenticated;
grant execute on function public.complete_review_upload(uuid) to authenticated;
grant execute on function public.remove_review_file(bigint,text) to authenticated;
