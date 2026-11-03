
alter table public.profiles drop constraint if exists dydem_custom_permission_shape;
alter table public.profiles alter column permissions set default '{"steps":[false,false,false,false,false,false,false],"add":false,"delete":false,"comment":false,"doc_add":false,"doc_delete":false}'::jsonb;
update public.profiles set permissions=permissions
 || jsonb_build_object('doc_add',coalesce((permissions->'steps'->5)='true'::jsonb,false),
 'doc_delete',coalesce((permissions->'steps'->5)='true'::jsonb,false))
where not(permissions ? 'doc_add') or not(permissions ? 'doc_delete');
alter table public.profiles add constraint dydem_custom_permission_shape check (
 jsonb_typeof(permissions)='object'
 and jsonb_typeof(permissions->'steps')='array'
 and jsonb_array_length(permissions->'steps')=7
 and jsonb_typeof(permissions->'add')='boolean'
 and jsonb_typeof(permissions->'delete')='boolean'
 and jsonb_typeof(permissions->'comment')='boolean'
 and jsonb_typeof(permissions->'doc_add')='boolean'
 and jsonb_typeof(permissions->'doc_delete')='boolean'
 and jsonb_typeof(permissions->'steps'->0)='boolean'
 and jsonb_typeof(permissions->'steps'->1)='boolean'
 and jsonb_typeof(permissions->'steps'->2)='boolean'
 and jsonb_typeof(permissions->'steps'->3)='boolean'
 and jsonb_typeof(permissions->'steps'->4)='boolean'
 and jsonb_typeof(permissions->'steps'->5)='boolean'
 and jsonb_typeof(permissions->'steps'->6)='boolean'
);
CREATE OR REPLACE FUNCTION public.dydem_can(p_permission text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select exists(
  select 1 from public.profiles where id=auth.uid() and active
   and (role='admin' or (role='custom' and (
     case
      when p_permission in ('add','delete','comment','doc_add','doc_delete')
       then permissions->>p_permission='true'
      when p_permission='step5' then
       coalesce((permissions->>'doc_add')::boolean,false)
       or coalesce((permissions->>'doc_delete')::boolean,false)
      when p_permission ~ '^step[0-6]$'
       then permissions->'steps'->((right(p_permission,1))::int)='true'::jsonb
      else false
     end
   )))
 )
 $function$
;

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
 v_prefix := '00000000-0000-4000-8000-00000000d1de/' || p_activity_id::text || '/' || v_id || '/';
 if v_path is null or left(v_path,length(v_prefix)) <> v_prefix then
  raise exception 'El archivo no pertenece a esta actividad';
 end if;
 select * into v_activity from public.activities
 where id=p_activity_id
   and project_id='00000000-0000-4000-8000-00000000d1de'
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
 perform public.validate_activity(v_updated,p_activity_id,v_activity.annex);
 v_rev := v_activity.revision+1;
 update public.activities
 set data=v_updated,revision=v_rev,updated_at=now(),updated_by=auth.uid()
 where id=p_activity_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(p_activity_id,auth.uid(),'update',v_activity.data,v_updated);
 return jsonb_build_object('id',p_activity_id,'revision',v_rev,'data',v_updated,'already_linked',false);
end
$function$
;

CREATE OR REPLACE FUNCTION public.begin_activity_upload(p_activity_id bigint, p_upload_id uuid, p_file_name text, p_storage_name text, p_file_size bigint, p_mime_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activity_upload_intents%rowtype;
 v_path text;v_mime text;
begin
 if auth.uid() is null or not public.dydem_can('doc_add') then
  raise exception 'No tienes permiso para subir anexos' using errcode='42501';
 end if;
 if not exists(select 1 from public.activities where id=p_activity_id and project_id='00000000-0000-4000-8000-00000000d1de' and deleted_at is null) then
  raise exception 'La actividad ya no está disponible';
 end if;
 if p_upload_id is null or p_file_size not between 1 and 524288000
  or p_file_name is null or length(btrim(p_file_name)) not between 1 and 255
  or p_storage_name is null or length(p_storage_name) not between 1 and 100
  or p_storage_name !~ '^[A-Za-z0-9._-]+$' or p_storage_name in ('.','..') then
  raise exception 'Los datos del archivo son inválidos';
 end if;
 v_mime:=coalesce(nullif(left(p_mime_type,255),''),'application/octet-stream');
 v_path:='00000000-0000-4000-8000-00000000d1de/'||p_activity_id||'/'||p_upload_id||'/'||p_storage_name;
 insert into public.activity_upload_intents
 (id,project_id,activity_id,uploaded_by,file_name,storage_name,file_size,mime_type,storage_path)
 values(p_upload_id,'00000000-0000-4000-8000-00000000d1de',p_activity_id,auth.uid(),p_file_name,p_storage_name,p_file_size,v_mime,v_path)
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
end $function$
;

CREATE OR REPLACE FUNCTION public.complete_activity_upload(p_upload_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_intent public.activity_upload_intents%rowtype;
 v_obj storage.objects%rowtype;
 v_data jsonb;v_ref jsonb;v_meta jsonb;
begin
 if auth.uid() is null or not public.is_active_user() then
  raise exception 'Debes iniciar sesión con una cuenta activa' using errcode='42501';
 end if;
 select * into v_intent from public.activity_upload_intents where id=p_upload_id for update;
 if not found or v_intent.uploaded_by is distinct from auth.uid() then
  raise exception 'La carga solicitada no está disponible' using errcode='42501';
 end if;
 if v_intent.status='linked' then
  select a.data into v_data from public.activities a where a.id=v_intent.activity_id and a.deleted_at is null;
  if v_data is null then raise exception 'La actividad ya no está disponible';end if;
  return jsonb_build_object('status','linked','already_linked',true,'id',v_intent.activity_id,
   'data',v_data,'revision',(select revision from public.activities where id=v_intent.activity_id));
 end if;
 if not public.dydem_can('doc_add') then raise exception 'No tienes permiso para completar la carga' using errcode='42501';end if;
 select * into v_obj from storage.objects where bucket_id='activity-attachments'
    and name=v_intent.storage_path and owner_id=v_intent.uploaded_by::text;
 if not found then
  return jsonb_build_object('status','pending','id',v_intent.activity_id,
   'name',v_intent.file_name,'message','El archivo todavía no está completo en Storage');
 end if;
 if coalesce((v_obj.metadata->>'size')::bigint,-1) <> v_intent.file_size then
  raise exception 'El tamaño almacenado no coincide con el archivo registrado';
 end if;
 v_meta:=jsonb_build_object('id',v_intent.id,'name',v_intent.file_name,
 'type',v_intent.mime_type,'size',v_intent.file_size,'path',v_intent.storage_path);
 v_ref:=public.attach_activity_file(v_intent.activity_id,v_meta);
 update public.activity_upload_intents set status='linked',linked_at=now()
 where id=v_intent.id;
 return jsonb_build_object('status','linked','already_linked',coalesce((v_ref->>'already_linked')::boolean,false),
  'id',v_intent.activity_id,'data',v_ref->'data','revision',v_ref->'revision');
end $function$
;

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
drop policy if exists dydem_attachments_upload on storage.objects;
create policy dydem_attachments_upload on storage.objects
 for insert to authenticated with check(
  bucket_id='activity-attachments' and public.dydem_can('doc_add')
  and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
 );
drop policy if exists dydem_attachments_delete on storage.objects;
create policy dydem_attachments_delete on storage.objects
 for delete to authenticated using(
  bucket_id='activity-attachments' and public.dydem_can('doc_delete')
  and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
 );
