-- Second factor for bearer invitation links: the URL alone must not activate an account.
alter table public.dydem_invitation_links
 add column if not exists code_digest text,
 add column if not exists failed_attempts integer not null default 0;
alter table public.dydem_invitation_links
 add constraint dydem_invite_code_digest_shape
 check(code_digest is null or code_digest ~ '^[0-9a-f]{64}$');
alter table public.dydem_invitation_links
 add constraint dydem_invite_attempts_range check(failed_attempts between 0 and 5);
-- No invitations existed at migration time. Require a code for every new invitation.
alter table public.dydem_invitation_links
 alter column code_digest set not null;

drop function if exists public.dydem_accept_invitation(text);
create or replace function public.dydem_accept_invitation(
 p_token_digest text,
 p_code_digest text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $accept$
declare link public.dydem_invitation_links%rowtype;
 target public.profiles%rowtype;
begin
 if auth.uid() is null then
  raise exception 'Primero verifica el enlace en Supabase Auth' using errcode='42501';
 end if;
 if p_token_digest is null or p_token_digest !~ '^[0-9a-f]{64}$' then
  raise exception 'El enlace es inválido' using errcode='42501';
 end if;
 if p_code_digest is null or p_code_digest !~ '^[0-9a-f]{64}$' then
  return jsonb_build_object('ok',false,'error','Código de activación no válido');
 end if;
 select * into link
 from public.dydem_invitation_links
 where token_digest=p_token_digest and invited_user=auth.uid()
  and accepted_at is null and revoked_at is null and expires_at>now()
 for update;
 if not found then
  raise exception 'Invitación inexistente, caducada, ya utilizada o no autorizada' using errcode='42501';
 end if;
 if link.code_digest<>p_code_digest then
  update public.dydem_invitation_links set failed_attempts=least(5,failed_attempts+1),
   revoked_at=case when failed_attempts+1>=5 then now() else revoked_at end
   where token_digest=p_token_digest;
  return jsonb_build_object('ok',false,
   'error',case when link.failed_attempts>=4 then
     'Se superó el número de intentos. Solicita una nueva invitación al Administrador.'
    else 'Código de activación incorrecto.' end);
 end if;
 select * into target from public.profiles where id=auth.uid() for update;
 if not found or not target.invite_pending or target.removed_at is not null
    or target.active or lower(target.email)<>lower(link.invited_email) then
  raise exception 'La cuenta no está autorizada para aceptar esta invitación' using errcode='42501';
 end if;
 update public.profiles set active=true,invite_pending=false where id=auth.uid();
 update public.dydem_invitation_links set accepted_at=now() where token_digest=p_token_digest;
 return jsonb_build_object('ok',true,'name',target.display_name,
   'email',target.email,'role',target.role,'activated',true);
end $accept$;

revoke all on function public.dydem_accept_invitation(text,text) from public,anon;
grant execute on function public.dydem_accept_invitation(text,text) to authenticated;
