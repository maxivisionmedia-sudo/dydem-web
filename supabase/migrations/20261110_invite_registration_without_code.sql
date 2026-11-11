-- DYDEM registro con enlace de un solo uso (sin PIN secundario).
-- Solo un admin autenticado emite el token; el invitado indica nombre,
-- contraseña y, en enlaces abiertos, correo.
create table if not exists public.dydem_registration_invites (
 token_digest text primary key check(token_digest ~ '^[0-9a-f]{64}$'),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 recipient_email text,
 assigned_role text not null default 'viewer'
  check(assigned_role in ('viewer','custom','admin')),
 assigned_permissions jsonb not null,
 claim_nonce uuid,
 claimed_at timestamptz,
 used_at timestamptz,
 created_user uuid references auth.users(id) on delete set null,
 revoked_at timestamptz,
 constraint dydem_register_invite_expiry check(expires_at>created_at)
);
alter table public.dydem_registration_invites enable row level security;
revoke all on public.dydem_registration_invites from public,anon,authenticated;
grant select,insert,update,delete on public.dydem_registration_invites to service_role;
create index if not exists dydem_registration_invites_active_idx
 on public.dydem_registration_invites(expires_at) where used_at is null and revoked_at is null;

-- One winner only, even when two browsers try the same link concurrently.
-- Only service_role can call these helpers; public/anon/authenticated cannot.
create or replace function public.dydem_claim_registration_invite(
 p_digest text,p_claim uuid,p_email text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $claim$
declare v public.dydem_registration_invites%rowtype;v_total int;
begin
 if current_user<>'service_role' then
  raise exception 'Solo el servidor puede registrar invitaciones' using errcode='42501';
 end if;
 if p_digest is null or p_digest !~ '^[0-9a-f]{64}$' or p_claim is null
  or p_email is null or p_email !~* '^[^ @]+@[^ @]+\.[^ @]+$' then
  return jsonb_build_object('ok',false,'error','Solicitud de registro inválida');
 end if;
 select * into v from public.dydem_registration_invites
  where token_digest=p_digest for update;
 if not found or v.used_at is not null or v.revoked_at is not null or v.expires_at<=now()
  then return jsonb_build_object('ok',false,'error','El enlace ha caducado, fue utilizado o no es válido');
 end if;
 if v.recipient_email is not null and lower(v.recipient_email)<>lower(p_email)
  then return jsonb_build_object('ok',false,'error','Este enlace está asignado a otro correo');
 end if;
 if v.claim_nonce is not null and v.claimed_at>now()-interval '3 minutes'
  then return jsonb_build_object('ok',false,'error','Este enlace se está utilizando. Reintenta en unos minutos');
 end if;
 select count(*) into v_total from public.profiles where active or invite_pending;
 if v_total>=5 then
  return jsonb_build_object('ok',false,'error','DYDEM ya alcanzó el límite de cinco usuarios');
 end if;
 update public.dydem_registration_invites set claim_nonce=p_claim,claimed_at=now()
  where token_digest=p_digest;
 return jsonb_build_object('ok',true,'role',v.assigned_role,
  'permissions',v.assigned_permissions,'recipient_email',v.recipient_email);
end $claim$;

create or replace function public.dydem_finish_registration_invite(
 p_digest text,p_claim uuid,p_user uuid,p_display_name text
) returns boolean language plpgsql security definer set search_path=public,pg_temp as $finish$
declare v public.dydem_registration_invites%rowtype; registered_email text;
begin
 if current_user<>'service_role' then
  raise exception 'Solo el servidor puede finalizar registros' using errcode='42501';
 end if;
 select * into v from public.dydem_registration_invites
  where token_digest=p_digest and claim_nonce=p_claim
   and claimed_at>now()-interval '3 minutes'
   and used_at is null and revoked_at is null and expires_at>now()
  for update;
 if not found then return false;end if;
 select email into registered_email from auth.users where id=p_user;
 if not found or (v.recipient_email is not null and lower(v.recipient_email)<>lower(registered_email))
  then return false;end if;
 if p_display_name is null or length(btrim(p_display_name)) not between 2 and 120 then return false;end if;
 insert into public.profiles(id,email,display_name,role,permissions,active,invite_pending,
  approval_reminders_enabled)
 values(p_user,registered_email,btrim(p_display_name),v.assigned_role,v.assigned_permissions,
  true,false,true)
 on conflict(id) do update set
  display_name=excluded.display_name,role=excluded.role,
  permissions=excluded.permissions,active=true,invite_pending=false,
  approval_reminders_enabled=true
 where public.profiles.active=false and public.profiles.removed_at is null;
 if not found then return false;end if;
 update public.dydem_registration_invites
 set used_at=now(),claim_nonce=null,claimed_at=null,created_user=p_user
 where token_digest=p_digest;
 return true;
end $finish$;

create or replace function public.dydem_release_registration_invite(p_digest text,p_claim uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $release$
begin
 if current_user<>'service_role' then
  raise exception 'Solo el servidor puede liberar invitaciones' using errcode='42501';end if;
 update public.dydem_registration_invites set claim_nonce=null,claimed_at=null
  where token_digest=p_digest and claim_nonce=p_claim and used_at is null;
 return found;
end $release$;

revoke all on function public.dydem_claim_registration_invite(text,uuid,text) from public,anon,authenticated;
revoke all on function public.dydem_finish_registration_invite(text,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.dydem_release_registration_invite(text,uuid) from public,anon,authenticated;
grant execute on function public.dydem_claim_registration_invite(text,uuid,text) to service_role;
grant execute on function public.dydem_finish_registration_invite(text,uuid,uuid,text) to service_role;
grant execute on function public.dydem_release_registration_invite(text,uuid) to service_role;

-- Email invitado: Supabase verifica el enlace enviado por correo. Después
-- de elegir contraseña y nombre, este RPC habilita el perfil existente.
create or replace function public.dydem_complete_email_invitation(p_display_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $email$
declare p public.profiles%rowtype;confirmed boolean;
begin
 if auth.uid() is null then raise exception 'Debes validar el enlace del correo' using errcode='42501';end if;
 if p_display_name is null or length(btrim(p_display_name)) not between 2 and 120 then
  raise exception 'Escribe un nombre de usuario de 2 a 120 caracteres';end if;
 select * into p from public.profiles where id=auth.uid() for update;
 if not found or p.active or not p.invite_pending or p.removed_at is not null then
  raise exception 'La invitación por correo no está pendiente o ya fue utilizada' using errcode='42501';
 end if;
 select email_confirmed_at is not null into confirmed from auth.users where id=auth.uid();
 if not coalesce(confirmed,false) then
  raise exception 'El correo no se ha verificado mediante su enlace';end if;
 update public.profiles set display_name=btrim(p_display_name),active=true,
   invite_pending=false where id=auth.uid();
 return jsonb_build_object('ok',true,'name',btrim(p_display_name),'email',p.email);
end $email$;
revoke all on function public.dydem_complete_email_invitation(text) from public,anon;
grant execute on function public.dydem_complete_email_invitation(text) to authenticated;

-- Evitar que las altas directas (no autorizadas) entren antes de ser aprobadas.
-- Las cuentas existentes no cambian.
create or replace function public.on_auth_user_created()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $trigger$
begin
 insert into public.profiles(id,email,display_name,role,active,invite_pending)
 values(new.id,coalesce(new.email,''),
  coalesce(nullif(new.raw_user_meta_data->>'display_name',''),new.email,''),
  'viewer',false,false)
 on conflict(id) do nothing;
 return new;
end $trigger$;

-- La versión anterior requería código y creaba usuarios prematuramente.
-- No hay invitaciones anteriores pendientes: eliminar mecanismo obsoleto.
drop function if exists public.dydem_accept_invitation(text,text);
drop function if exists public.dydem_resume_invitation(text);
drop table if exists public.dydem_invitation_links;
