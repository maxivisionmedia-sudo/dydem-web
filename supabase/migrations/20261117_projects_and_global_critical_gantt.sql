-- DYDEM cross-project isolation and administrator global Gantt.
alter table public.projects add column if not exists description text not null default '';
create or replace function public.dydem_create_project(p_name text,p_description text default '')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $p$
declare v public.projects%rowtype;
begin
 if not public.is_dydem_admin() then raise exception 'Solo el Administrador puede crear proyectos' using errcode='42501';end if;
 if p_name is null or length(btrim(p_name)) not between 3 and 120 then raise exception 'Nombre de proyecto de 3 a 120 caracteres';end if;
 if length(coalesce(p_description,''))>3000 then raise exception 'Descripción demasiado larga';end if;
 if exists(select 1 from public.projects where lower(btrim(name))=lower(btrim(p_name))) then raise exception 'Ese nombre de proyecto ya existe';end if;
 insert into public.projects(id,name,description) values(gen_random_uuid(),btrim(p_name),btrim(coalesce(p_description,''))) returning * into v;
 return jsonb_build_object('id',v.id,'name',v.name,'description',v.description,'created_at',v.created_at);
end $p$;
revoke all on function public.dydem_create_project(text,text) from public,anon;
grant execute on function public.dydem_create_project(text,text) to authenticated;
create table if not exists public.dydem_critical_config(
 activity_id bigint primary key references public.activities(id) on delete cascade,
 included boolean not null default true,
 predecessors bigint[] not null default array[]::bigint[],
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id) on delete set null,
 constraint dydem_critical_max_links check(cardinality(predecessors)<=120));
alter table public.dydem_critical_config enable row level security;
revoke all on public.dydem_critical_config from public,anon,authenticated;
grant select on public.dydem_critical_config to authenticated;
create policy dydem_critical_admin_read on public.dydem_critical_config for select to authenticated using(public.is_dydem_admin());
create or replace function public.dydem_set_critical_activity(
 p_activity_id bigint,p_included boolean,p_predecessors bigint[]
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $c$
declare deps bigint[];cycles boolean;
begin
 if not public.is_dydem_admin() then raise exception 'Solo el Administrador puede editar la ruta crítica' using errcode='42501';end if;
 if p_included is null or p_predecessors is null or cardinality(p_predecessors)>120 then raise exception 'Datos inválidos de ruta crítica';end if;
 if not exists(select 1 from public.activities where id=p_activity_id and deleted_at is null) then raise exception 'Actividad inexistente';end if;
 select coalesce(array_agg(distinct u.p order by u.p),array[]::bigint[]) into deps from unnest(p_predecessors) u(p);
 if p_activity_id=any(deps) then raise exception 'Una actividad no puede depender de sí misma';end if;
 if exists(select 1 from unnest(deps) u(p) where not exists(select 1 from public.activities a where a.id=u.p and a.deleted_at is null))
 then raise exception 'Una dependencia no corresponde a una actividad activa';end if;
 perform pg_advisory_xact_lock(7112026,42);
 with recursive path(node,visited) as(
  select p,array[p] from unnest(deps) x(p)
  union all
  select nxt,visited||nxt
  from path walk
  join public.dydem_critical_config c on c.activity_id=walk.node
  cross join lateral unnest(c.predecessors) nxt
  where not nxt=any(visited)
 )
 select exists(select 1 from path where node=p_activity_id) into cycles;
 if cycles then raise exception 'Dependencia circular: revisa las actividades relacionadas';end if;
 insert into public.dydem_critical_config(activity_id,included,predecessors,updated_by,updated_at)
 values(p_activity_id,p_included,deps,auth.uid(),now())
 on conflict(activity_id) do update set included=excluded.included,predecessors=excluded.predecessors,updated_by=excluded.updated_by,updated_at=now();
 return jsonb_build_object('activity_id',p_activity_id,'included',p_included,'predecessors',to_jsonb(deps));
end $c$;
revoke all on function public.dydem_set_critical_activity(bigint,boolean,bigint[]) from public,anon;
grant execute on function public.dydem_set_critical_activity(bigint,boolean,bigint[]) to authenticated;
CREATE OR REPLACE FUNCTION public.create_activity(p_title text, p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_project uuid;v_counter_key text;v_start date; v_week int; v_code text; v_seq int; v_annex text; v_id bigint; v_data jsonb;
begin
 if not public.dydem_can('add') then raise exception 'Acceso denegado' using errcode='42501'; end if;
 if trim(coalesce(p_title,''))='' or length(p_title)>1000 then raise exception 'Descripción no válida'; end if;
 select id into v_project from public.projects where id=p_project_id;
 if not found then raise exception 'Proyecto no disponible';end if;
 perform pg_advisory_xact_lock(7112026);
 v_start:=date_trunc('week',now() at time zone 'America/Mexico_City')::date;
 v_week:=to_char(v_start,'IW')::integer;
 v_code:=to_char(v_start,'IYYY')||'-S'||to_char(v_start,'IW');
 v_counter_key:=case when v_project='00000000-0000-4000-8000-00000000d1de'::uuid then v_code else v_project::text||':'||v_code end;
 insert into public.annex_counters(week_code,last_used) values(v_counter_key,1)
 on conflict(week_code) do update set last_used=public.annex_counters.last_used+1
 returning last_used into v_seq;
 v_annex:=v_week::text||'_'||v_seq::text;
 insert into public.activities(project_id,data,annex,updated_by) values(v_project,'{}'::jsonb,v_annex,auth.uid()) returning id into v_id;
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

CREATE OR REPLACE FUNCTION public.begin_activity_upload(p_activity_id bigint, p_upload_id uuid, p_file_name text, p_storage_name text, p_file_size bigint, p_mime_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activity_upload_intents%rowtype;
 v_path text;v_mime text;v_project uuid;
begin
 if auth.uid() is null or not public.dydem_can('doc_add') then
  raise exception 'No tienes permiso para subir anexos' using errcode='42501';
 end if;
 select project_id into v_project from public.activities where id=p_activity_id and deleted_at is null;
 if not found then
  raise exception 'La actividad ya no está disponible';
 end if;
 if p_upload_id is null or p_file_size not between 1 and 524288000
  or p_file_name is null or length(btrim(p_file_name)) not between 1 and 255
  or p_storage_name is null or length(p_storage_name) not between 1 and 100
  or p_storage_name !~ '^[A-Za-z0-9._-]+$' or p_storage_name in ('.','..') then
  raise exception 'Los datos del archivo son inválidos';
 end if;
 v_mime:=coalesce(nullif(left(p_mime_type,255),''),'application/octet-stream');
 v_path:=v_project::text||'/'||p_activity_id||'/'||p_upload_id||'/'||p_storage_name;
 insert into public.activity_upload_intents
 (id,project_id,activity_id,uploaded_by,file_name,storage_name,file_size,mime_type,storage_path)
 values(p_upload_id,v_project,p_activity_id,auth.uid(),p_file_name,p_storage_name,p_file_size,v_mime,v_path)
 on conflict(id) do nothing;
 select * into v_record from public.activity_upload_intents where id=p_upload_id for update;
 if v_record.uploaded_by is distinct from auth.uid() or
    v_record.activity_id is distinct from p_activity_id or
    v_record.file_name is distinct from p_file_name or
    v_record.file_size is distinct from p_file_size or
    v_record.storage_name is distinct from p_storage_name then
  raise exception 'Conflicto en el identificador de carga' using errcode='42501';
 end if;
 return jsonb_build_object('id',v_record.id,'activity_id',v_record.activity_id,
 'name',v_record.file_name,'size',v_record.file_size,'type',v_record.mime_type,
 'path',v_record.storage_path,'status',v_record.status);
end $function$;

CREATE OR REPLACE FUNCTION public.begin_review_upload(p_activity_id bigint, p_upload_id uuid, p_file_name text, p_storage_name text, p_file_size bigint, p_mime_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.proposal_upload_intents%rowtype;v_path text;v_mime text;v_project uuid;
begin
 if auth.uid() is null or not public.dydem_can_review_file(p_activity_id,'add') then
  raise exception 'Solo Administrador puede subir archivos para Revisión' using errcode='42501';end if;
 select project_id into v_project from public.activities where id=p_activity_id and deleted_at is null;
 if not found then
  raise exception 'Actividad no disponible';end if;
 if p_upload_id is null or p_file_size not between 1 and 524288000
  or p_file_name is null or length(btrim(p_file_name)) not between 1 and 255
  or p_storage_name is null or length(p_storage_name) not between 1 and 100
  or p_storage_name !~ '^[A-Za-z0-9._-]+$' or p_storage_name in ('.','..') then
  raise exception 'Archivo para Revisión inválido';end if;
 v_mime:=coalesce(nullif(left(p_mime_type,255),''),'application/octet-stream');
 v_path:=v_project::text||'/'||p_activity_id||'/'||p_upload_id||'/'||p_storage_name;
 insert into public.proposal_upload_intents
 (id,project_id,activity_id,uploaded_by,file_name,storage_name,file_size,mime_type,storage_path)
 values(p_upload_id,v_project,p_activity_id,auth.uid(),p_file_name,p_storage_name,p_file_size,v_mime,v_path)
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

CREATE OR REPLACE FUNCTION public.attach_activity_file(p_activity_id bigint, p_file jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_activity public.activities%rowtype;
 v_path text; v_id text; v_name text; v_type text;
 v_size bigint; v_file jsonb; v_updated jsonb;
 v_object storage.objects%rowtype;
 v_rev integer; v_prefix text;
begin
 if auth.uid() is null or not public.dydem_can('doc_add') then
  raise exception 'No tienes permiso de modificar Documentado' using errcode='42501';
 end if;
 if jsonb_typeof(p_file) <> 'object' then
  raise exception 'Referencia de archivo inválida';
 end if;
 v_id := p_file->>'id';
 v_name := p_file->>'name';
 v_path := p_file->>'path';
 v_type := coalesce(p_file->>'type','application/octet-stream');
 if v_id is null or v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  raise exception 'Identificador de archivo inválido';
 end if;
 if v_name is null or length(btrim(v_name)) < 1 or length(v_name) > 255 then
  raise exception 'El archivo necesita un nombre válido';
 end if;
 if p_file->>'size' is null or (p_file->>'size') !~ '^[0-9]+$' then
  raise exception 'El tamaño del archivo debe ser numérico';
 end if;
 v_size := (p_file->>'size')::bigint;
 if v_size < 1 or v_size > 500 * 1024 * 1024 then
  raise exception 'El archivo debe tener un tamaño entre 1 byte y 500 MB';
 end if;
 v_prefix := (select project_id::text from public.activities where id=p_activity_id and deleted_at is null) || '/' || p_activity_id::text || '/' || v_id || '/';
 if v_path is null or left(v_path,length(v_prefix)) <> v_prefix then
  raise exception 'El archivo no pertenece a esta actividad';
 end if;
 select * into v_activity from public.activities
 where id=p_activity_id
    and deleted_at is null
 for update;
 if not found then raise exception 'Actividad no disponible'; end if;
 select * into v_object from storage.objects
 where bucket_id='activity-attachments' and name=v_path and owner_id=auth.uid()::text;
 if not found then
  raise exception 'El archivo no terminó de cargarse en Storage o no pertenece al usuario';
 end if;
 if coalesce((v_object.metadata->>'size')::bigint,-1) <> v_size then
  raise exception 'El tamaño del archivo guardado no coincide';
 end if;
 if exists (
   select 1 from jsonb_array_elements(coalesce(v_activity.data->'attachments','[]'::jsonb)) elem
   where elem->>'id'=v_id or elem->>'path'=v_path
 ) then
  return jsonb_build_object('id',p_activity_id,'revision',v_activity.revision,'data',v_activity.data,'already_linked',true);
 end if;
 v_file := jsonb_build_object('id',v_id,'name',v_name,'path',v_path,'type',v_type,'size',v_size);
 v_updated := jsonb_set(
   v_activity.data,'{attachments}',
   coalesce(v_activity.data->'attachments','[]'::jsonb) || jsonb_build_array(v_file),
   true
 );
 -- Marcar Documentado al adjuntar solo si ya pasó Verificación.
 if v_updated->'steps'->>4='true' then
  v_updated := jsonb_set(v_updated,'{steps,5}','true'::jsonb,false);
 end if;
 v_updated:=public.dydem_recompute_stages(v_updated);
 perform public.validate_activity(v_updated,p_activity_id,v_activity.annex);
 v_rev := v_activity.revision+1;
 update public.activities
 set data=v_updated,revision=v_rev,updated_at=now(),updated_by=auth.uid()
 where id=p_activity_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(p_activity_id,auth.uid(),'update',v_activity.data,v_updated);
 return jsonb_build_object('id',p_activity_id,'revision',v_rev,'data',v_updated,'already_linked',false);
end
$function$;

CREATE OR REPLACE FUNCTION public.remove_activity_file(p_activity_id bigint, p_file_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_activity public.activities%rowtype;
 v_file jsonb;
 v_after jsonb;
 v_next jsonb;
 v_revision integer;
begin
 if auth.uid() is null or not public.dydem_can('doc_delete') then
  raise exception 'No tienes permiso para quitar anexos' using errcode='42501';
 end if;
 select * into v_activity from public.activities
 where id=p_activity_id 
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
 v_next:=public.dydem_recompute_stages(v_next);
 perform public.validate_activity(v_next,p_activity_id,v_activity.annex);
 v_revision:=v_activity.revision+1;
 update public.activities set data=v_next,revision=v_revision,updated_at=now(),updated_by=auth.uid()
 where id=p_activity_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(p_activity_id,auth.uid(),'update',v_activity.data,v_next);
 return jsonb_build_object('id',p_activity_id,'revision',v_revision,'data',v_next,'removed_file',v_file);
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
 select * into r from public.activities where id=p_activity_id  and deleted_at is null for update;
 if not found then raise exception 'Actividad no disponible';end if;
 if not public.dydem_can_review_file(r.id,'delete') then
   raise exception 'La Revisión terminó; solo el Administrador puede retirar archivos' using errcode='42501';
 end if;
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
 where id=v_intent.activity_id  and deleted_at is null
 for update;
 if not found then raise exception 'Actividad no disponible';end if;
 if not public.dydem_can_review_file(v_activity.id,'add') then
   raise exception 'La Revisión terminó antes de completar la carga; solo el Administrador puede añadir archivos' using errcode='42501';
 end if;
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

CREATE OR REPLACE FUNCTION public.dydem_can_review_file(p_activity_id bigint, p_action text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_data jsonb;
begin
 if auth.uid() is null or not public.is_active_user()
    or p_action not in ('add','delete') then return false;end if;
 select data into v_data from public.activities where id=p_activity_id
  
  and deleted_at is null;
 if not found then return false;end if;
 if public.is_dydem_admin() then return true;end if;
 if coalesce((v_data->'steps'->>1)::boolean,false) or not coalesce((v_data->'steps'->>0)::boolean,false) then
  return false;end if;
 return public.dydem_can(case when p_action='add' then 'doc_add' else 'doc_delete' end)
 or coalesce(v_data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(auth.uid()::text);
end $function$;

CREATE OR REPLACE FUNCTION public.dydem_prepare_comment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_author text; v_data jsonb; v_refs jsonb;v_project uuid;
begin
 if auth.uid() is null or not public.is_active_user() then
  raise exception 'Se requiere una cuenta activa de DYDEM' using errcode='42501';
 end if;
 if new.body is null or char_length(btrim(new.body)) not between 1 and 2000 then
  raise exception 'El comentario debe contener entre 1 y 2000 caracteres';
 end if;
 if not exists (
   select 1 from public.activities a
   where a.id=new.activity_id
   and a.deleted_at is null
 ) then
  raise exception 'La actividad ya no está disponible para comentarios';
 end if;
 select a.data,a.project_id into v_data,v_project from public.activities a
 where a.id=new.activity_id and a.deleted_at is null for share;
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
 new.project_id := v_project;
 new.author_id := auth.uid();
 new.author_name := v_author;
 new.body := btrim(new.body);
 new.created_at := now();
 return new;
end $function$;
revoke all on function public.create_activity(text,uuid) from public,anon;
grant execute on function public.create_activity(text,uuid) to authenticated;
drop policy if exists activities_read on public.activities;
create policy activities_read on public.activities for select to authenticated using(public.is_active_user() and deleted_at is null and exists(select 1 from public.projects pr where pr.id=project_id));
drop policy if exists dydem_comments_read on public.activity_comments;
create policy dydem_comments_read on public.activity_comments for select to authenticated using(public.is_active_user() and exists(select 1 from public.activities a where a.id=activity_id and a.project_id=activity_comments.project_id and a.deleted_at is null));
drop policy if exists dydem_comments_post on public.activity_comments;
create policy dydem_comments_post on public.activity_comments for insert to authenticated with check(public.dydem_can('comment') and author_id=auth.uid() and exists(select 1 from public.activities a where a.id=activity_id and a.project_id=activity_comments.project_id and a.deleted_at is null));
drop policy if exists dydem_comments_admin_delete on public.activity_comments;
create policy dydem_comments_admin_delete on public.activity_comments for delete to authenticated using(public.is_dydem_admin() and exists(select 1 from public.activities a where a.id=activity_id and a.project_id=activity_comments.project_id and a.deleted_at is null));
create or replace function public.dydem_storage_activity_path(p_path text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $s$
 select exists(select 1 from public.activities a where a.deleted_at is null
 and a.project_id::text=split_part(p_path,'/',1)
 and a.id::text=split_part(p_path,'/',2));
$s$;
revoke all on function public.dydem_storage_activity_path(text) from public,anon;
grant execute on function public.dydem_storage_activity_path(text) to authenticated;
drop policy if exists dydem_attachments_read on storage.objects;
create policy dydem_attachments_read on storage.objects for select to authenticated using(bucket_id='activity-attachments' and public.is_active_user() and public.dydem_storage_activity_path(name));
drop policy if exists dydem_attachments_upload on storage.objects;
create policy dydem_attachments_upload on storage.objects for insert to authenticated with check(bucket_id='activity-attachments' and public.is_active_user() and public.dydem_storage_activity_path(name)
 and ((public.dydem_can('doc_add') and not public.dydem_is_review_storage_path(name)) or public.dydem_review_storage_path(name,'add')));
drop policy if exists dydem_attachments_delete on storage.objects;
create policy dydem_attachments_delete on storage.objects for delete to authenticated using(bucket_id='activity-attachments' and public.is_active_user() and public.dydem_storage_activity_path(name)
 and ((public.dydem_can('doc_delete') and not public.dydem_is_review_storage_path(name)) or public.dydem_review_storage_path(name,'delete')));
