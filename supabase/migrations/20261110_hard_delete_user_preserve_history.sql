-- DYDEM: true account deletion frees the email for a BRAND-NEW identity.
-- Preserve work history and attachment files, but never carry over the old
-- profile, password, approval rights or UUID to the next invited user.
create table if not exists public.dydem_departed_users (
 id uuid primary key,
 display_name text not null,
 removed_at timestamptz not null default now()
);
alter table public.dydem_departed_users enable row level security;
revoke all on public.dydem_departed_users from public,anon,authenticated;
-- No personal email or password is ever stored in this audit name table.

alter table public.activities alter column updated_by drop not null;
alter table public.activities drop constraint if exists activities_updated_by_fkey;
alter table public.activities add constraint activities_updated_by_fkey
  foreign key (updated_by) references auth.users(id) on delete set null;

alter table public.activity_comments alter column author_id drop not null;
alter table public.activity_comments drop constraint if exists activity_comments_author_id_fkey;
alter table public.activity_comments add constraint activity_comments_author_id_fkey
  foreign key (author_id) references auth.users(id) on delete set null;

alter table public.activity_history alter column changed_by drop not null;
alter table public.activity_history drop constraint if exists activity_history_changed_by_fkey;
alter table public.activity_history add constraint activity_history_changed_by_fkey
  foreign key (changed_by) references auth.users(id) on delete set null;

alter table public.activity_upload_intents alter column uploaded_by drop not null;
alter table public.activity_upload_intents drop constraint if exists activity_upload_intents_uploaded_by_fkey;
alter table public.activity_upload_intents add constraint activity_upload_intents_uploaded_by_fkey
  foreign key (uploaded_by) references auth.users(id) on delete set null;

alter table public.proposal_upload_intents alter column uploaded_by drop not null;
alter table public.proposal_upload_intents drop constraint if exists proposal_upload_intents_uploaded_by_fkey;
alter table public.proposal_upload_intents add constraint proposal_upload_intents_uploaded_by_fkey
  foreign key (uploaded_by) references auth.users(id) on delete set null;

alter table public.dydem_invitation_links alter column created_by drop not null;
alter table public.dydem_invitation_links drop constraint if exists dydem_invitation_links_created_by_fkey;
alter table public.dydem_invitation_links add constraint dydem_invitation_links_created_by_fkey
  foreign key (created_by) references auth.users(id) on delete set null;

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
    select 1 from public.activities a where a.deleted_at is null
      and (coalesce(a.data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(old.id::text)
       or coalesce(a.data->'responsibles'->'authorization','[]'::jsonb) @> jsonb_build_array(old.id::text)
       or coalesce(a.data->'responsibles'->'verification','[]'::jsonb) @> jsonb_build_array(old.id::text))
   )
 order by 2,1;
$function$;

-- Pending unaccepted invitations are invalidated before account removal.
-- Auth user deletion cascades to profiles and invited_user links; all previously
-- referenced authors/history remain in their original activity records.
