
create or replace function public.dydem_recompute_stages(p_data jsonb)
returns jsonb language plpgsql immutable set search_path=public,pg_temp as $norm$
declare d jsonb:=p_data;st jsonb; k text; i integer; count_assigned integer;votes integer; all_signed boolean;
begin
 if jsonb_typeof(d)<>'object' or jsonb_typeof(d->'steps')<>'array' or jsonb_array_length(d->'steps')<>7 then raise exception 'Actividad inválida';end if;
 st:=d->'steps';
 for k,i in select * from (values ('review',1),('authorization',2),('verification',4)) as x(k,i) loop
  if jsonb_typeof(d->'responsibles'->k)<>'array' or jsonb_typeof(d->'approvals'->k)<>'array' then raise exception 'Responsables inválidos: %',k;end if;
  count_assigned:=jsonb_array_length(d->'responsibles'->k);
  votes:=jsonb_array_length(d->'approvals'->k);
  all_signed:=count_assigned>0 and votes=count_assigned
    and not exists(select 1 from jsonb_array_elements_text(d->'responsibles'->k) as u(id)
                   where not exists(select 1 from jsonb_array_elements_text(d->'approvals'->k) as v(id) where v.id=u.id));
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
end $norm$;



create or replace function public.validate_activity(p_data jsonb,p_id bigint,p_annex text)
returns void language plpgsql set search_path=public,pg_temp as $validate$
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
end $validate$;



create or replace function public.list_dydem_responsibles()
returns table(id uuid,display_name text)
language sql stable security definer set search_path=public,pg_temp as $users$
 select p.id,coalesce(nullif(btrim(p.display_name),''),split_part(p.email,'@',1))::text
 from public.profiles p
 where public.is_active_user() and p.active
 order by 2,1
$users$;
revoke all on function public.list_dydem_responsibles() from public,anon;
grant execute on function public.list_dydem_responsibles() to authenticated;



create or replace function public.set_activity_responsibles(p_id bigint,p_stage integer,p_users uuid[])
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $assign$
declare r public.activities%rowtype; d jsonb; k text; valid_users integer;assigned jsonb; n integer;
begin
 if auth.uid() is null or not public.is_active_user() then raise exception 'Sesión requerida' using errcode='42501';end if;
 if p_stage not in (1,2,4) then raise exception 'Etapa de aprobación no válida';end if;
 if not public.dydem_can('step'||p_stage::text) then raise exception 'No tienes permiso para asignar responsables de esta etapa' using errcode='42501';end if;
 if p_users is null or array_length(p_users,1)>50 then raise exception 'Selección inválida de usuarios';end if;
 if exists(select 1 from unnest(p_users) u where u is null) then raise exception 'Usuario inválido';end if;
 if (select count(*) from unnest(p_users)) is distinct from (select count(distinct u) from unnest(p_users) u) then
  raise exception 'No se permiten responsables duplicados';
 end if;
 if exists(select 1 from unnest(p_users) u where not exists(select 1 from public.profiles p where p.id=u and p.active)) then
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
 d:=public.dydem_recompute_stages(d);
 perform public.validate_activity(d,p_id,r.annex);
 n:=r.revision+1;
 update public.activities set data=d,revision=n,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data) values(p_id,auth.uid(),'update',r.data,d);
 return jsonb_build_object('id',p_id,'revision',n,'data',d);
end $assign$;
revoke all on function public.set_activity_responsibles(bigint,integer,uuid[]) from public,anon;
grant execute on function public.set_activity_responsibles(bigint,integer,uuid[]) to authenticated;



create or replace function public.vote_activity_stage(p_id bigint,p_stage integer,p_approved boolean)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $vote$
declare r public.activities%rowtype;d jsonb;k text;n integer;v jsonb;vote_id text;
begin
 if auth.uid() is null or not public.is_active_user() then raise exception 'Sesión requerida' using errcode='42501';end if;
 if p_stage not in (1,2,4) or p_approved is null then raise exception 'Aprobación inválida';end if;
 k:=case p_stage when 1 then 'review' when 2 then 'authorization' else 'verification' end;
 select * into r from public.activities where id=p_id and deleted_at is null for update;
 if not found then raise exception 'Actividad no encontrada';end if;
 vote_id:=auth.uid()::text;
 if not exists(select 1 from jsonb_array_elements_text(r.data->'responsibles'->k) u(id) where u.id=vote_id) then
  raise exception 'Tu usuario no está asignado como responsable de esta etapa' using errcode='42501';
 end if;
 if p_approved and (
   (p_stage=1 and r.data->'steps'->>0<>'true')
   or (p_stage=2 and r.data->'steps'->>1<>'true')
   or (p_stage=4 and (r.data->'steps'->>2<>'true' or r.data->'steps'->>3<>'true'))
 ) then raise exception 'No se han completado los requisitos previos de esta aprobación';end if;
 select coalesce(jsonb_agg(x.id),'[]'::jsonb) into v
 from jsonb_array_elements_text(r.data->'approvals'->k) x(id) where x.id<>vote_id;
 if p_approved then v:=v||jsonb_build_array(vote_id);end if;
 if v=r.data->'approvals'->k then return jsonb_build_object('id',p_id,'revision',r.revision,'data',r.data);end if;
 d:=jsonb_set(r.data,array['approvals',k],v,false);
 d:=public.dydem_recompute_stages(d);
 perform public.validate_activity(d,p_id,r.annex);
 n:=r.revision+1;
 update public.activities set data=d,revision=n,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data) values(p_id,auth.uid(),'update',r.data,d);
 return jsonb_build_object('id',p_id,'revision',n,'data',d);
end $vote$;
revoke all on function public.vote_activity_stage(bigint,integer,boolean) from public,anon;
grant execute on function public.vote_activity_stage(bigint,integer,boolean) to authenticated;


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
   'reviewers','','reviewAnnex','','authorizer','','progress',0,'verification',0,
   'attachments','[]'::jsonb,'completedDate','','workCompletedDate','','responsibles','{"review":[],"authorization":[],"verification":[]}'::jsonb,'approvals','{"review":[],"authorization":[],"verification":[]}'::jsonb,'steps','[false,false,false,false,false,false,false]'::jsonb);
 perform public.validate_activity(v_data,v_id,v_annex);
 update public.activities set data=v_data where id=v_id;
 insert into public.activity_history(activity_id,changed_by,action,new_data)
 values(v_id,auth.uid(),'create',v_data);
 return jsonb_build_object('id',v_id,'data',v_data,'revision',1);
end $function$
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
$function$
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
 v_next:=public.dydem_recompute_stages(v_next);
 perform public.validate_activity(v_next,p_activity_id,v_activity.annex);
 v_revision:=v_activity.revision+1;
 update public.activities set data=v_next,revision=v_revision,updated_at=now(),updated_by=auth.uid()
 where id=p_activity_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
 values(p_activity_id,auth.uid(),'update',v_activity.data,v_next);
 return jsonb_build_object('id',p_activity_id,'revision',v_revision,'data',v_next,'removed_file',v_file);
end $function$
;


-- Reiniciar únicamente los datos anteriores de Revisión, Autorización y Verificación,
-- conservando actividad, progreso de obra, fechas, comentarios y archivos.
do $reset$
declare row public.activities%rowtype;new_data jsonb;
begin
 for row in select * from public.activities where deleted_at is null for update loop
  new_data:=row.data||jsonb_build_object(
   'reviewers','','reviewAnnex','','authorizer','','verification',0,
   'responsibles','{"review":[],"authorization":[],"verification":[]}'::jsonb,'approvals','{"review":[],"authorization":[],"verification":[]}'::jsonb,
   'workCompletedDate',''
  );
  new_data:=public.dydem_recompute_stages(new_data);
  perform public.validate_activity(new_data,row.id,row.annex);
  update public.activities set data=new_data,revision=row.revision+1,
   updated_at=now() where id=row.id;
  insert into public.activity_history(activity_id,changed_by,action,old_data,new_data)
   values(row.id,null,'update',row.data,new_data);
 end loop;
end $reset$;
