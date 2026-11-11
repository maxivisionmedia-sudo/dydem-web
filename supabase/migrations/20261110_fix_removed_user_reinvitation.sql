-- Reinviting removed users: keep audit identities, never keep live invitations.
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
 if target.removed_at is not null then
  -- Idempotency: even an archived account from an older release must have
  -- no outstanding activation links, login access, or reminder permission.
  update public.dydem_invitation_links set revoked_at=now()
   where invited_user=p_user_id and revoked_at is null and accepted_at is null;
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
 update public.dydem_invitation_links set revoked_at=now()
   where invited_user=p_user_id and revoked_at is null and accepted_at is null;
 update public.profiles set active=false,invite_pending=false,
   approval_reminders_enabled=false,removed_at=now()
 where id=p_user_id;
 return jsonb_build_object('ok',true,'id',p_user_id,'display_name',target.display_name,
   'history_preserved',true);
end $function$;

-- Legacy removals (before this fix) may have left invite_pending=true.
update public.dydem_invitation_links l set revoked_at=now()
 from public.profiles p where l.invited_user=p.id and p.removed_at is not null
 and l.accepted_at is null and l.revoked_at is null;

update public.profiles set invite_pending=false,active=false,approval_reminders_enabled=false
 where removed_at is not null and (invite_pending or active or approval_reminders_enabled);
