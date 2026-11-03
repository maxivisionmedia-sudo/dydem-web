
-- DYDEM: Propuesta (1) y Avance de Obra (4), solo Administrador.
-- Revisión (2), Autorización (3), Verificación (5), por usuario responsable asignado.
-- Los permisos generales antiguos para estas cinco etapas dejan de aplicarse.
update public.profiles
set permissions=jsonb_set(
  permissions,'{steps}',
  (select jsonb_agg(case when ordinality between 1 and 5 then 'false'::jsonb else value end order by ordinality)
   from jsonb_array_elements(permissions->'steps') with ordinality as stage(value,ordinality)),
  false)
where role='custom' and permissions->'steps' is not null;
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
      when p_permission in ('step0','step1','step2','step3','step4')
       then false
      when p_permission='step6'
       then permissions->'steps'->6='true'::jsonb
      else false
     end
   )))
 )
 $function$
;

CREATE OR REPLACE FUNCTION public.list_dydem_stage_responsibles(p_stage integer)
 RETURNS TABLE(id uuid, display_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
 if auth.uid() is null or not public.is_dydem_admin() then
  raise exception 'Solo el Administrador puede consultar los responsables elegibles' using errcode='42501';
 end if;
 if p_stage not in (1,2,4) then raise exception 'Etapa no válida';end if;
 return query
  select p.id,coalesce(nullif(btrim(p.display_name),''),split_part(p.email,'@',1))::text
  from public.profiles p
  where p.active
  order by 2,1;
end $function$
;

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
 d:=public.dydem_recompute_stages(d);
 perform public.validate_activity(d,p_id,r.annex);
 n:=r.revision+1;
 update public.activities set data=d,revision=n,updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.activity_history(activity_id,changed_by,action,old_data,new_data) values(p_id,auth.uid(),'update',r.data,d);
 return jsonb_build_object('id',p_id,'revision',n,'data',d);
end $function$
;

CREATE OR REPLACE FUNCTION public.vote_activity_stage(p_id bigint, p_stage integer, p_approved boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.activities%rowtype;d jsonb;k text;n integer;v jsonb;vote_id text;
begin
 if auth.uid() is null or not public.is_active_user() then raise exception 'Sesión requerida' using errcode='42501';end if;
 if p_stage not in (1,2,4) or p_approved is null then raise exception 'Aprobación inválida';end if;
 -- El único permiso para confirmar es estar asignado como responsable.
 -- La cuenta debe estar activa y cada voto se vincula a auth.uid().
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
end $function$
;
