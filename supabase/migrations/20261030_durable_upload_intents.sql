
-- Durable upload intent: recorded before any bytes are transmitted.
-- The intent persists through browser refresh/network interruption.
create table if not exists public.activity_upload_intents(
 id uuid primary key,
 project_id uuid not null default '00000000-0000-4000-8000-00000000d1de' references public.projects(id),
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
create index if not exists activity_upload_intents_owner_status_idx
 on public.activity_upload_intents(uploaded_by,status,created_at);
alter table public.activity_upload_intents enable row level security;
drop policy if exists activity_upload_intents_owner_read on public.activity_upload_intents;
create policy activity_upload_intents_owner_read on public.activity_upload_intents
for select to authenticated using(public.is_active_user() and (uploaded_by=auth.uid() or public.is_dydem_admin()));
revoke all on public.activity_upload_intents from anon,authenticated;
grant select on public.activity_upload_intents to authenticated;

create or replace function public.begin_activity_upload(
 p_activity_id bigint,p_upload_id uuid,p_file_name text,p_storage_name text,p_file_size bigint,p_mime_type text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $begin_upload$
declare v_record public.activity_upload_intents%rowtype;
 v_path text;v_mime text;
begin
 if auth.uid() is null or not public.dydem_can('step5') then
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
end $begin_upload$;
revoke all on function public.begin_activity_upload(bigint,uuid,text,text,bigint,text) from public,anon;
grant execute on function public.begin_activity_upload(bigint,uuid,text,text,bigint,text) to authenticated;

create or replace function public.complete_activity_upload(p_upload_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $complete_upload$
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
 if not public.dydem_can('step5') then raise exception 'No tienes permiso para completar la carga' using errcode='42501';end if;
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
end $complete_upload$;
revoke all on function public.complete_activity_upload(uuid) from public,anon;
grant execute on function public.complete_activity_upload(uuid) to authenticated;
