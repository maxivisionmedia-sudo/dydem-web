-- DYDEM: allow an invitee to inspect ONLY their own pending email invite.
-- profiles_read intentionally rejects inactive users, which previously hid
-- the pending profile and wrongly displayed "already used".
-- Authorization comes from the verified Supabase Auth session, never from
-- untrusted email, metadata, or a user-supplied user_id.
create or replace function public.dydem_check_email_invitation()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $body$
declare
 p public.profiles%rowtype;
 verified boolean := false;
begin
 if auth.uid() is null then
  raise exception 'Primero abre y verifica el enlace recibido por correo'
    using errcode='42501';
 end if;
 select * into p from public.profiles where id=auth.uid();
 if not found or p.removed_at is not null then
  return jsonb_build_object('ok',false,'reason','not_found');
 end if;
 if p.active or not p.invite_pending then
  return jsonb_build_object('ok',false,'reason','not_pending');
 end if;
 select u.email_confirmed_at is not null
    and lower(coalesce(u.email,''))=lower(p.email)
 into verified
 from auth.users u where u.id=auth.uid();
 if not coalesce(verified,false) then
  return jsonb_build_object('ok',false,'reason','not_verified');
 end if;
 return jsonb_build_object('ok',true,'email',p.email);
end
$body$;

revoke all on function public.dydem_check_email_invitation() from public,anon;
grant execute on function public.dydem_check_email_invitation() to authenticated;
