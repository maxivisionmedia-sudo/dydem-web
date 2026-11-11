-- Allow a verified invite session to finish activation after a reload.
-- This does NOT activate the account, expose a token, or bypass the separate code.
create or replace function public.dydem_resume_invitation(p_token_digest text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $body$
 select auth.uid() is not null
  and p_token_digest ~ '^[0-9a-f]{64}$'
  and exists(
   select 1 from public.dydem_invitation_links l
   join public.profiles p on p.id=l.invited_user
   where l.token_digest=p_token_digest and l.invited_user=auth.uid()
    and l.accepted_at is null and l.revoked_at is null and l.expires_at>now()
    and p.invite_pending and not p.active and p.removed_at is null
  );
$body$;
revoke all on function public.dydem_resume_invitation(text) from public,anon;
grant execute on function public.dydem_resume_invitation(text) to authenticated;
