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
 for v_other in select id,data from public.activities where project_id=v_record.project_id and deleted_at is null and
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

CREATE OR REPLACE FUNCTION public.dydem_remove_user(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare target public.profiles%rowtype; remaining_admins integer;pending_count integer;
 pending_detail text;
begin
 if auth.uid() is null or not public.is_dydem_admin() then
  raise exception 'Solo un Administrador puede remover usuarios' using errcode='42501';
 end if;
 if p_user_id is null then raise exception 'Selecciona un usuario válido';end if;
 if p_user_id=auth.uid() then
  raise exception 'No puedes remover tu propia cuenta de Administrador';
 end if;
 select * into target from public.profiles where id=p_user_id for update;
 if not found then raise exception 'El usuario no existe';end if;
 -- Keep only the historical name and opaque old UUID; the email is removed
 -- by deleting the old auth identity and its cascading profile.
 insert into public.dydem_departed_users(id,display_name,removed_at)
 values(target.id,coalesce(nullif(btrim(target.display_name),''),'Usuario anterior'),
        coalesce(target.removed_at,now()))
 on conflict(id) do update set display_name=excluded.display_name;
 -- Preserve user-uploaded files; they become owned by the Administrator.
 -- This updates Storage ownership metadata, never the file bytes or paths.
 update storage.objects set owner=auth.uid(),owner_id=auth.uid()::text
 where bucket_id='activity-attachments'
  and (owner=p_user_id or owner_id=p_user_id::text);
 if target.removed_at is not null then
  -- Idempotency: even an archived account from an older release must have
  -- no outstanding activation links, login access, or reminder permission.
  update public.dydem_registration_invites set revoked_at=now()
   where revoked_at is null and used_at is null
    and (created_by=p_user_id or recipient_email=lower(target.email));
  delete from public.dydem_project_members where user_id=p_user_id;
  update public.profiles set active=false,invite_pending=false,
    approval_reminders_enabled=false where id=p_user_id;
  return jsonb_build_object('ok',true,'already_removed',true,'id',p_user_id);
 end if;
 if target.active and target.role='admin' then
  select count(*) into remaining_admins
   from public.profiles where active and role='admin' and removed_at is null;
  if remaining_admins<=1 then
   raise exception 'Debe quedar al menos un Administrador activo';
  end if;
 end if;
 -- No eliminar asignaciones ni votos de forma automática: un pendiente
 -- debe reasignarse primero, conservando el historial de aprobaciones.
 select count(*),left(string_agg(
   coalesce(nullif(btrim(a.annex),''),a.id::text)||' ('||st.name||')',
   ', ' order by a.id,st.name),250)
 into pending_count,pending_detail
 from public.activities a
 cross join lateral (values
    ('review','Revisión'),
    ('authorization','Autorización'),
    ('verification','Verificación')
 ) as st(key,name)
 where a.deleted_at is null
  and coalesce(a.data->'responsibles'->st.key,'[]'::jsonb) @> jsonb_build_array(p_user_id::text)
  and not coalesce(a.data->'approvals'->st.key,'[]'::jsonb) @> jsonb_build_array(p_user_id::text);
 if pending_count>0 then
  raise exception 'Este usuario tiene % aprobación(es) pendientes: %. Reasígnalas antes de removerlo.',
   pending_count,pending_detail;
 end if;
 -- Revoke ALL unaccepted invitations, including a link generated just before
 -- removing the account; otherwise an old link could revive it later.
 update public.dydem_registration_invites set revoked_at=now()
   where revoked_at is null and used_at is null
    and (created_by=p_user_id or recipient_email=lower(target.email));
 delete from public.dydem_project_members where user_id=p_user_id;
 update public.profiles set active=false,invite_pending=false,
   approval_reminders_enabled=false,removed_at=now()
 where id=p_user_id;
 return jsonb_build_object('ok',true,'id',p_user_id,'display_name',target.display_name,
   'history_preserved',true);
end $function$;