-- DYDEM: admin-issued single-use invitation links with server-side verification.
-- The URL carries a Supabase Auth invite token hash (bearer secret), not a public site password.
-- This table stores only SHA-256 of that bearer token and is NEVER exposed to signed-in users.
alter table public.profiles
 add column if not exists invite_pending boolean not null default false;

create table if not exists public.dydem_invitation_links (
 token_digest text primary key check(token_digest ~ '^[0-9a-f]{64}$'),
 invited_user uuid not null references auth.users(id) on delete cascade,
 invited_email text not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 accepted_at timestamptz,
 revoked_at timestamptz,
 constraint dydem_invite_expires_after_creation check(expires_at>created_at)
);
create unique index if not exists dydem_single_pending_invitation_per_user
 on public.dydem_invitation_links(invited_user)
 where accepted_at is null and revoked_at is null;
create index if not exists dydem_invitation_user_lookup
 on public.dydem_invitation_links(invited_user,created_at desc);
alter table public.dydem_invitation_links enable row level security;
revoke all on public.dydem_invitation_links from public,anon,authenticated;
grant select,insert,update,delete on public.dydem_invitation_links to service_role;

create or replace function public.dydem_accept_invitation(p_token_digest text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $accept$
declare link public.dydem_invitation_links%rowtype;
 target public.profiles%rowtype;
begin
 if auth.uid() is null then
  raise exception 'Primero verifica el enlace de invitación en Supabase Auth' using errcode='42501';
 end if;
 if p_token_digest is null or p_token_digest !~ '^[0-9a-f]{64}$' then
  raise exception 'El código de invitación es inválido' using errcode='42501';
 end if;
 select * into link
 from public.dydem_invitation_links
 where token_digest=p_token_digest and invited_user=auth.uid()
  and accepted_at is null and revoked_at is null and expires_at>now()
 for update;
 if not found then
  raise exception 'Invitación inexistente, expirada, ya utilizada o sin autorización' using errcode='42501';
 end if;
 select * into target from public.profiles
 where id=auth.uid() for update;
 if not found or not target.invite_pending or target.removed_at is not null
    or target.active or lower(target.email)<>lower(link.invited_email) then
  raise exception 'Esta cuenta no está habilitada para aceptar la invitación' using errcode='42501';
 end if;
 -- The session was issued by verifyOtp(type=invite), the token digest is known
 -- only to the administrator-issued recipient, and the account matches.
 update public.profiles set active=true,invite_pending=false
  where id=auth.uid();
 update public.dydem_invitation_links set accepted_at=now()
  where token_digest=p_token_digest;
 return jsonb_build_object('ok',true,'name',target.display_name,
   'email',target.email,'role',target.role,'activated',true);
end $accept$;
revoke all on function public.dydem_accept_invitation(text) from public,anon;
grant execute on function public.dydem_accept_invitation(text) to authenticated;

-- A removed user must not be reactivated through an outstanding invitation.
-- The existing safe-removal function has a removed_at guard enforced on acceptance.
