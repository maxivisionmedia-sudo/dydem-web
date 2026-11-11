
-- DYDEM: Propuesta (descripción y archivos opcionales) + Dudas (hilo separado de Notas).
alter table public.activity_comments add column if not exists thread text not null default 'notes';
alter table public.activity_comments drop constraint if exists activity_comments_thread_check;
alter table public.activity_comments add constraint activity_comments_thread_check check(thread in ('notes','dudas'));
create index if not exists activity_comments_thread_idx on public.activity_comments(project_id,activity_id,thread,created_at);

create table if not exists public.proposal_upload_intents (
 id uuid primary key,
 project_id uuid not null default '00000000-0000-4000-8000-00000000d1de'::uuid references public.projects(id),
 activity_id bigint not null references public.activities(id),
 uploaded_by uuid not null references auth.users(id),
 file_name text not null,
 storage_name text not null,
 file_size bigint not null check(file_size between 1 and 524288000),
 mime_type text not null default 'application/octet-stream',
 storage_path text not null unique,
 status text not null default 'pending' check(status in ('pending','linked')),
 created_at timestamptz not null default now(),
 linked_at timestamptz
);
alter table public.proposal_upload_intents enable row level security;
drop policy if exists proposal_upload_intents_owner_read on public.proposal_upload_intents;
create policy proposal_upload_intents_owner_read on public.proposal_upload_intents for select to authenticated
 using(public.is_active_user() and (uploaded_by=auth.uid() or public.is_dydem_admin()));
revoke all on public.proposal_upload_intents from public,anon,authenticated;
grant select on public.proposal_upload_intents to authenticated;

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
 if jsonb_typeof(p_data->'proposalAttachments')<>'array' then raise exception 'Formato de archivos de Propuesta inválido';end if;
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
end $function$
;
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
end $function$
;
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
   'attachments','[]'::jsonb,'proposalAttachments','[]'::jsonb,'proposalDescription','','completedDate','','workCompletedDate','','responsibles','{"review":[],"authorization":[],"verification":[]}'::jsonb,'approvals','{"review":[],"authorization":[],"verification":[]}'::jsonb,'steps','[false,false,false,false,false,false,false]'::jsonb);
 perform public.validate_activity(v_data,v_id,v_annex);
 update public.activities set data=v_data where id=v_id;
 insert into public.activity_history(activity_id,changed_by,action,new_data)
 values(v_id,auth.uid(),'create',v_data);
 return jsonb_build_object('id',v_id,'data',v_data,'revision',1);
end $function$
;

-- Initialize only new optional fields; do not change original Evidence links.
do $backfill$
declare r public.activities%rowtype; d jsonb;
begin
 for r in select * from public.activities where data is not null and jsonb_typeof(data)='object'
   and (not(data ? 'proposalAttachments') or not(data ? 'proposalDescription')) for update
 loop
  d:=r.data;
  if not(d ? 'proposalAttachments') then d:=jsonb_set(d,'{proposalAttachments}','[]'::jsonb,true); end if;
  if not(d ? 'proposalDescription') then d:=jsonb_set(d,'{proposalDescription}','""'::jsonb,true); end if;
  perform public.validate_activity(d,r.id,r.annex);
  update public.activities set data=d, revision=r.revision+1,updated_at=now()
   where id=r.id;
  insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
   values(r.id,null,'update',r.data,d);
 end loop;
end $backfill$;

create or replace function public.begin_proposal_upload(
 p_activity_id bigint,p_upload_id uuid,p_file_name text,p_storage_name text,p_file_size bigint,p_mime_type text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $start$
declare v_record public.proposal_upload_intents%rowtype;v_path text;v_mime text;
begin
 if auth.uid() is null or not public.is_dydem_admin() then
  raise exception 'Solo Administrador puede subir archivos de Propuesta' using errcode='42501';end if;
 if not exists(select 1 from public.activities where id=p_activity_id and project_id='00000000-0000-4000-8000-00000000d1de'::uuid and deleted_at is null) then
  raise exception 'Actividad no disponible';end if;
 if p_upload_id is null or p_file_size not between 1 and 524288000
  or p_file_name is null or length(btrim(p_file_name)) not between 1 and 255
  or p_storage_name is null or length(p_storage_name) not between 1 and 100
  or p_storage_name !~ '^[A-Za-z0-9._-]+$' or p_storage_name in ('.','..') then
  raise exception 'Archivo de Propuesta inválido';end if;
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
  raise exception 'Conflicto en el identificador de carga de Propuesta' using errcode='42501';end if;
 return jsonb_build_object('id',v_record.id,'activity_id',v_record.activity_id,
 'name',v_record.file_name,'size',v_record.file_size,'type',v_record.mime_type,
 'path',v_record.storage_path,'status',v_record.status,'section','proposal');
end $start$;

create or replace function public.complete_proposal_upload(p_upload_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $complete$
declare v_intent public.proposal_upload_intents%rowtype;
 v_obj storage.objects%rowtype;v_activity public.activities%rowtype;
 v_data jsonb;v_meta jsonb;v_revision integer;v_existing boolean;
begin
 if auth.uid() is null or not public.is_dydem_admin() then
  raise exception 'Solo Administrador puede registrar archivos de Propuesta' using errcode='42501';end if;
 select * into v_intent from public.proposal_upload_intents where id=p_upload_id for update;
 if not found or v_intent.uploaded_by is distinct from auth.uid() then
  raise exception 'Carga de Propuesta no disponible' using errcode='42501';end if;
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
 select exists(select 1 from jsonb_array_elements(coalesce(v_activity.data->'proposalAttachments','[]'::jsonb)) elem
  where elem->>'id'=p_upload_id::text or elem->>'path'=v_intent.storage_path) into v_existing;
 if v_existing then
  update public.proposal_upload_intents set status='linked',linked_at=now() where id=p_upload_id;
  return jsonb_build_object('status','linked','already_linked',true,'id',v_activity.id,'data',v_activity.data,'revision',v_activity.revision);
 end if;
 v_meta:=jsonb_build_object('id',v_intent.id,'name',v_intent.file_name,
  'type',v_intent.mime_type,'size',v_intent.file_size,'path',v_intent.storage_path);
 v_data:=jsonb_set(v_activity.data,'{proposalAttachments}',
  coalesce(v_activity.data->'proposalAttachments','[]'::jsonb)||jsonb_build_array(v_meta),true);
 perform public.validate_activity(v_data,v_activity.id,v_activity.annex);
 v_revision:=v_activity.revision+1;
 update public.activities set data=v_data,revision=v_revision,updated_at=now(),updated_by=auth.uid()
 where id=v_activity.id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(v_activity.id,auth.uid(),'update',v_activity.data,v_data);
 update public.proposal_upload_intents set status='linked',linked_at=now() where id=p_upload_id;
 return jsonb_build_object('status','linked','already_linked',false,'id',v_activity.id,'data',v_data,'revision',v_revision);
end $complete$;

create or replace function public.remove_proposal_file(p_activity_id bigint,p_file_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $remove$
declare r public.activities%rowtype;v_file jsonb;v_after jsonb;v_next jsonb;v_rev integer;
begin
 if auth.uid() is null or not public.is_dydem_admin() then
  raise exception 'Solo Administrador puede eliminar archivos de Propuesta' using errcode='42501';end if;
 select * into r from public.activities where id=p_activity_id and project_id='00000000-0000-4000-8000-00000000d1de'::uuid and deleted_at is null for update;
 if not found then raise exception 'Actividad no disponible';end if;
 select value into v_file from jsonb_array_elements(coalesce(r.data->'proposalAttachments','[]'::jsonb)) as elem(value)
  where value->>'id'=p_file_id limit 1;
 if v_file is null then return jsonb_build_object('id',r.id,'revision',r.revision,'data',r.data,'already_removed',true);end if;
 select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_after
 from jsonb_array_elements(r.data->'proposalAttachments') with ordinality as elem(value,ordinality)
 where value->>'id' is distinct from p_file_id;
 v_next:=jsonb_set(r.data,'{proposalAttachments}',v_after,false);
 perform public.validate_activity(v_next,r.id,r.annex);
 v_rev:=r.revision+1;
 update public.activities set data=v_next,revision=v_rev,updated_at=now(),updated_by=auth.uid() where id=r.id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(r.id,auth.uid(),'update',r.data,v_next);
 return jsonb_build_object('id',r.id,'revision',v_rev,'data',v_next,'removed_file',v_file);
end $remove$;
revoke all on function public.begin_proposal_upload(bigint,uuid,text,text,bigint,text) from public,anon;
revoke all on function public.complete_proposal_upload(uuid) from public,anon;
revoke all on function public.remove_proposal_file(bigint,text) from public,anon;
grant execute on function public.begin_proposal_upload(bigint,uuid,text,text,bigint,text) to authenticated;
grant execute on function public.complete_proposal_upload(uuid) to authenticated;
grant execute on function public.remove_proposal_file(bigint,text) to authenticated;
