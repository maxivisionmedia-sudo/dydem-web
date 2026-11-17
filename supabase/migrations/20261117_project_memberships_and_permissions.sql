-- DYDEM: miembros por proyecto; la administración conserva acceso global.
create table if not exists public.dydem_project_members(
 project_id uuid not null references public.projects(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 assigned_at timestamptz not null default now(),
 assigned_by uuid references auth.users(id) on delete set null,
 primary key(project_id,user_id));
create index if not exists dydem_project_members_user_idx on public.dydem_project_members(user_id,project_id);
alter table public.dydem_project_members enable row level security;
revoke all on public.dydem_project_members from public,anon,authenticated;
grant select on public.dydem_project_members to authenticated;
drop policy if exists dydem_project_members_read on public.dydem_project_members;
create policy dydem_project_members_read on public.dydem_project_members
 for select to authenticated using(public.is_dydem_admin() or user_id=auth.uid());
insert into public.dydem_project_members(project_id,user_id)
select '00000000-0000-4000-8000-00000000d1de'::uuid,id from public.profiles where active and role<>'admin'
on conflict(project_id,user_id) do nothing;

create or replace function public.dydem_has_project_access(pid uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $f$
select exists(select 1 from public.profiles u where u.id=auth.uid() and u.active
 and (u.role='admin' or exists(select 1 from public.dydem_project_members m where m.project_id=pid and m.user_id=u.id)));
$f$;
create or replace function public.dydem_has_activity_access(aid bigint)
returns boolean language sql stable security definer set search_path=public,pg_temp as $f$
select exists(select 1 from public.activities a where a.id=aid and a.deleted_at is null and public.dydem_has_project_access(a.project_id));
$f$;
revoke all on function public.dydem_has_project_access(uuid),public.dydem_has_activity_access(bigint) from public,anon;
grant execute on function public.dydem_has_project_access(uuid),public.dydem_has_activity_access(bigint) to authenticated;

create or replace function public.dydem_set_project_users(pid uuid,ids uuid[])
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $f$
declare n int;
begin
 if not public.is_dydem_admin() then raise exception 'Solo el Administrador puede asignar usuarios por proyecto' using errcode='42501';end if;
 if pid is null or ids is null or cardinality(ids)>100 then raise exception 'Selección inválida';end if;
 perform 1 from public.projects where id=pid for update;
 if not found then raise exception 'Proyecto inexistente';end if;
 if cardinality(ids)<> (select count(distinct id) from unnest(ids) x(id)) then raise exception 'Usuarios duplicados o nulos';end if;
 if exists(select 1 from unnest(ids) x(id) left join public.profiles p on p.id=x.id
   where p.id is null or not p.active or p.role='admin') then
   raise exception 'Solo pueden asignarse usuarios activos no administradores; los administradores ya tienen acceso global';end if;
 if exists(select 1 from public.dydem_project_members m
   join public.activities a on a.project_id=m.project_id and a.deleted_at is null
   where m.project_id=pid and not (m.user_id=any(ids))
   and exists(select 1 from (values('review'),('authorization'),('verification')) step(k)
     where coalesce(a.data->'responsibles'->step.k,'[]'::jsonb) @> jsonb_build_array(m.user_id::text))) then
   raise exception 'Reasigna los responsables de las actividades antes de retirarles acceso al proyecto' using errcode='23514';end if;
 delete from public.dydem_project_members where project_id=pid and not (user_id=any(ids));
 insert into public.dydem_project_members(project_id,user_id,assigned_by)
  select pid,x,auth.uid() from unnest(ids) x on conflict(project_id,user_id) do nothing;
 select count(*) into n from public.dydem_project_members where project_id=pid;
 return jsonb_build_object('ok',true,'project_id',pid,'members',n);
end $f$;
revoke all on function public.dydem_set_project_users(uuid,uuid[]) from public,anon;
grant execute on function public.dydem_set_project_users(uuid,uuid[]) to authenticated;

drop policy if exists projects_read on public.projects;
create policy projects_read on public.projects for select to authenticated using(public.dydem_has_project_access(id));
drop policy if exists activities_read on public.activities;
create policy activities_read on public.activities for select to authenticated using(deleted_at is null and public.dydem_has_project_access(project_id));
drop policy if exists dydem_comments_read on public.activity_comments;
create policy dydem_comments_read on public.activity_comments for select to authenticated
 using(public.dydem_has_project_access(project_id) and exists(select 1 from public.activities a where a.id=activity_id and a.project_id=activity_comments.project_id and a.deleted_at is null));
drop policy if exists dydem_comments_post on public.activity_comments;
create policy dydem_comments_post on public.activity_comments for insert to authenticated
 with check(public.dydem_has_project_access(project_id) and public.dydem_can('comment') and author_id=auth.uid()
  and exists(select 1 from public.activities a where a.id=activity_id and a.project_id=activity_comments.project_id and a.deleted_at is null));
drop policy if exists activity_upload_intents_owner_read on public.activity_upload_intents;
create policy activity_upload_intents_owner_read on public.activity_upload_intents for select to authenticated
 using(public.dydem_has_project_access(project_id) and (uploaded_by=auth.uid() or public.is_dydem_admin()));
drop policy if exists proposal_upload_intents_owner_read on public.proposal_upload_intents;
create policy proposal_upload_intents_owner_read on public.proposal_upload_intents for select to authenticated
 using(public.dydem_has_project_access(project_id) and (uploaded_by=auth.uid() or public.is_dydem_admin()));

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
 if not (public.dydem_has_activity_access(p_activity_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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

CREATE OR REPLACE FUNCTION public.begin_activity_upload(p_activity_id bigint, p_upload_id uuid, p_file_name text, p_storage_name text, p_file_size bigint, p_mime_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activity_upload_intents%rowtype;
 v_path text;v_mime text;v_project uuid;
begin
 if not (public.dydem_has_activity_access(p_activity_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
 if not (public.dydem_has_activity_access(p_activity_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
 if not (public.dydem_has_activity_access(p_activity_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
 if not (public.dydem_has_activity_access(p_activity_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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

CREATE OR REPLACE FUNCTION public.set_activity_responsibles(p_id bigint, p_stage integer, p_users uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.activities%rowtype; d jsonb; k text; valid_users integer;assigned jsonb; n integer;
begin
 if not (public.dydem_has_activity_access(p_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
 if auth.uid() is null or not public.is_active_user() then raise exception 'Sesión requerida' using errcode='42501';end if;
 if p_stage not in (1,2,4) then raise exception 'Etapa de aprobación no válida';end if;
 if not public.is_dydem_admin() then raise exception 'Solo el Administrador puede asignar o modificar los responsables' using errcode='42501';end if;
 if p_users is null or array_length(p_users,1)>50 then raise exception 'Selección inválida de usuarios';end if;
 if p_stage=2 and coalesce(array_length(p_users,1),0)=0 then
  raise exception 'Autorizado requiere al menos un usuario responsable; no puedes dejar la asignación vacía' using errcode='23514';
 end if;
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
 if exists(select 1 from unnest(p_users) x(uid) where not exists(
 select 1 from public.profiles p where p.id=x.uid and p.active and (p.role='admin' or
 exists(select 1 from public.dydem_project_members m where m.project_id=r.project_id and m.user_id=p.id)))) then
 raise exception 'Asigna solo responsables con acceso al proyecto' using errcode='42501';end if;
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

CREATE OR REPLACE FUNCTION public.update_activity(p_id bigint, p_expected_revision integer, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activities%rowtype; v_next int; i int; v_norm jsonb;
begin
 if not (public.dydem_has_activity_access(p_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
 if not (public.dydem_has_activity_access(p_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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

CREATE OR REPLACE FUNCTION public.vote_activity_stage(p_id bigint, p_stage integer, p_approved boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.activities%rowtype;d jsonb;k text;n integer;v jsonb;vote_id text;unassigned boolean;admin_user boolean;
begin
 if not (public.dydem_has_activity_access(p_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
  if p_stage=2 then
   raise exception 'Autorizado requiere al menos un responsable asignado antes de confirmar' using errcode='23514';
  end if;
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

CREATE OR REPLACE FUNCTION public.delete_activity(p_id bigint, p_expected_revision integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_record public.activities%rowtype; v_other record; v_data jsonb;
begin
 if not (public.dydem_has_activity_access(p_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
end $function$;

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
 if not (exists(select 1 from public.activity_upload_intents i where i.id=p_upload_id and public.dydem_has_activity_access(i.activity_id))) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
 if not (exists(select 1 from public.proposal_upload_intents i where i.id=p_upload_id and public.dydem_has_activity_access(i.activity_id))) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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

CREATE OR REPLACE FUNCTION public.create_activity(p_title text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_start date; v_week int; v_code text; v_seq int; v_annex text; v_id bigint; v_data jsonb;
begin
 if not (public.dydem_has_project_access('00000000-0000-4000-8000-00000000d1de'::uuid)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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

CREATE OR REPLACE FUNCTION public.create_activity(p_title text, p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_project uuid;v_counter_key text;v_start date; v_week int; v_code text; v_seq int; v_annex text; v_id bigint; v_data jsonb;
begin
 if not (public.dydem_has_project_access(p_project_id)) then raise exception 'Acceso restringido a usuarios de este proyecto' using errcode='42501';end if;
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
 if not public.dydem_has_project_access(v_project) then
  raise exception 'No tienes acceso a este proyecto' using errcode='42501';end if;
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
 select data into v_data from public.activities where id=p_activity_id and public.dydem_has_activity_access(p_activity_id)
  
  and deleted_at is null;
 if not found then return false;end if;
 if public.is_dydem_admin() then return true;end if;
 if coalesce((v_data->'steps'->>1)::boolean,false) or not coalesce((v_data->'steps'->>0)::boolean,false) then
  return false;end if;
 return public.dydem_can(case when p_action='add' then 'doc_add' else 'doc_delete' end)
 or coalesce(v_data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(auth.uid()::text);
end $function$;

CREATE OR REPLACE FUNCTION public.dydem_storage_activity_path(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select exists(select 1 from public.activities a where a.deleted_at is null
 and a.project_id::text=split_part(p_path,'/',1)
 and a.id::text=split_part(p_path,'/',2) and public.dydem_has_project_access(a.project_id));
$function$;

CREATE OR REPLACE FUNCTION public.list_dydem_responsibles()
 RETURNS TABLE(id uuid, display_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select p.id,
  coalesce(nullif(btrim(p.display_name),''),split_part(p.email,'@',1))::text
 from public.profiles p
 where public.is_active_user()
  and (public.is_dydem_admin() or p.id=auth.uid() or exists(select 1 from public.dydem_project_members a join public.dydem_project_members b on b.project_id=a.project_id and b.user_id=p.id where a.user_id=auth.uid()))
  and (p.active or exists(
   select 1 from public.activities a
   where a.deleted_at is null and
    (coalesce(a.data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(p.id::text)
      or coalesce(a.data->'responsibles'->'authorization','[]'::jsonb) @> jsonb_build_array(p.id::text)
      or coalesce(a.data->'responsibles'->'verification','[]'::jsonb) @> jsonb_build_array(p.id::text))
  ))
 union all
 select old.id,old.display_name from public.dydem_departed_users old
 where public.is_active_user()
   and exists(
    select 1 from public.activities a where a.deleted_at is null and public.dydem_has_project_access(a.project_id)
      and (coalesce(a.data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(old.id::text)
       or coalesce(a.data->'responsibles'->'authorization','[]'::jsonb) @> jsonb_build_array(old.id::text)
       or coalesce(a.data->'responsibles'->'verification','[]'::jsonb) @> jsonb_build_array(old.id::text))
   )
 order by 2,1;
$function$;

create or replace function public.dydem_list_project_stage_responsibles(pid uuid,stage integer)
 returns table(id uuid,display_name text) language plpgsql stable security definer set search_path=public,pg_temp as $f$
begin
 if not public.is_dydem_admin() then raise exception 'Solo el Administrador puede seleccionar responsables' using errcode='42501';end if;
 if stage not in (1,2,4) then raise exception 'Etapa inválida';end if;
 return query select p.id,coalesce(nullif(btrim(p.display_name),''),split_part(p.email,'@',1))::text
 from public.profiles p where p.active and
 (p.role='admin' or exists(select 1 from public.dydem_project_members m where m.project_id=pid and m.user_id=p.id))
 order by 2,1;
end $f$;
revoke all on function public.dydem_list_project_stage_responsibles(uuid,integer) from public,anon;
grant execute on function public.dydem_list_project_stage_responsibles(uuid,integer) to authenticated;