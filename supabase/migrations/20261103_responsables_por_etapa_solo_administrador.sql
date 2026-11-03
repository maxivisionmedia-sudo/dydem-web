-- DYDEM: asignación exclusiva del administrador y candidatos con permiso por etapa.

create or replace function public.list_dydem_stage_responsibles(p_stage integer)
returns table(id uuid,display_name text)
language plpgsql stable security definer set search_path=public,pg_temp
as $responsibles$
begin
 if auth.uid() is null or not public.is_dydem_admin() then
  raise exception 'Solo el Administrador puede consultar los responsables elegibles' using errcode='42501';
 end if;
 if p_stage not in (1,2,4) then raise exception 'Etapa no válida';end if;
 return query
  select p.id,coalesce(nullif(btrim(p.display_name),''),split_part(p.email,'@',1))::text
  from public.profiles p
  where p.active and (
   p.role='admin' or (p.role='custom' and p.permissions->'steps'->p_stage='true'::jsonb)
  )
  order by 2,1;
end $responsibles$;
revoke all on function public.list_dydem_stage_responsibles(integer) from public,anon;
grant execute on function public.list_dydem_stage_responsibles(integer) to authenticated;

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
      and (p.role='admin' or (p.role='custom' and p.permissions->'steps'->p_stage='true'::jsonb))
  )) then
  raise exception 'Solo puedes asignar usuarios activos con permiso para esta etapa';
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
 if not public.dydem_can('step'||p_stage::text) then
  raise exception 'Tu usuario no tiene permiso para aprobar esta etapa' using errcode='42501';
 end if;
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
