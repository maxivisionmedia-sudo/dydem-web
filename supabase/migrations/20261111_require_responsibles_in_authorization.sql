-- DYDEM: Stage 3 (Autorizado) requires ≥1 assigned responsible.
-- Keep admin fallback for Revisión (1) and Verificación (4) unchanged.
-- Existing activities with zero assigned authorizers remain pending and editable.
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
    or (i<>2 and count_assigned=0 and coalesce((d->'manualApprovals'->>k)::boolean,false));
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
 if coalesce((p_data->'manualApprovals'->>'authorization')::boolean,false) then
  raise exception 'Autorizado debe ser confirmado por usuarios responsables asignados, no mediante aprobación administrativa' using errcode='23514';
 end if;
 if p_data->'steps'->>2='true' and jsonb_array_length(p_data->'responsibles'->'authorization')=0 then
  raise exception 'La etapa Autorizado requiere al menos un responsable' using errcode='23514';
 end if;
 if p_data->'steps' is distinct from (public.dydem_recompute_stages(p_data)->'steps') then
  raise exception 'El estado de las etapas no coincide con las aprobaciones registradas';
 end if;
end $function$;