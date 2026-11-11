-- Race-condition hardening: serialize review file changes and Dudas against the stage-completion transaction.
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
 new.project_id := '00000000-0000-4000-8000-00000000d1de';
 new.author_id := auth.uid();
 new.author_name := v_author;
 new.body := btrim(new.body);
 new.created_at := now();
 return new;
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

