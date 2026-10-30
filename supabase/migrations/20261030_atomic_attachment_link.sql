
-- DYDEM: registro transaccional del anexo una vez completada la carga en Storage.
-- No permite editar la actividad salvo agregar un único archivo a Documentado.
create or replace function public.attach_activity_file(p_activity_id bigint, p_file jsonb)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp
as $attach$
declare
 v_activity public.activities%rowtype;
 v_path text; v_id text; v_name text; v_type text;
 v_size bigint; v_file jsonb; v_updated jsonb;
 v_object storage.objects%rowtype;
 v_rev integer; v_prefix text;
begin
 if auth.uid() is null or not public.dydem_can('step5') then
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
$attach$;
revoke all on function public.attach_activity_file(bigint,jsonb) from public,anon;
grant execute on function public.attach_activity_file(bigint,jsonb) to authenticated;
