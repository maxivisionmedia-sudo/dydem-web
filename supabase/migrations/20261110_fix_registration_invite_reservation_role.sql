-- DYDEM: correct invitation reservation for the server-only RPC.
-- The Edge Function uses the service_role key; actual PostgREST requests can
-- reach service_role without request.jwt.claim.role being set. A SECURITY
-- DEFINER function changes current_user, so neither check is reliable.
-- PostgreSQL EXECUTE ACL is the authorization gate: service_role only.
CREATE OR REPLACE FUNCTION public.dydem_claim_registration_invite(p_digest text, p_claim uuid, p_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v public.dydem_registration_invites%rowtype;v_total int;
begin
 -- Authorized by GRANT EXECUTE TO service_role alone (no JWT claim required).
 if p_digest is null or p_digest !~ '^[0-9a-f]{64}$' or p_claim is null
  or p_email is null or p_email !~* '^[^ @]+@[^ @]+\.[^ @]+$' then
  return jsonb_build_object('ok',false,'error','Solicitud de registro inválida');
 end if;
 perform pg_advisory_xact_lock(7192026,2);
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
 v_total:=v_total+(select count(*) from public.dydem_registration_invites
  where claim_nonce is not null and claimed_at>now()-interval '3 minutes'
   and used_at is null and revoked_at is null and token_digest<>p_digest);
 if v_total>=5 then
  return jsonb_build_object('ok',false,'error','DYDEM ya alcanzó el límite de cinco usuarios');
 end if;
 update public.dydem_registration_invites set claim_nonce=p_claim,claimed_at=now()
  where token_digest=p_digest;
 return jsonb_build_object('ok',true,'role',v.assigned_role,
  'permissions',v.assigned_permissions,'recipient_email',v.recipient_email);
end $function$;

CREATE OR REPLACE FUNCTION public.dydem_finish_registration_invite(p_digest text, p_claim uuid, p_user uuid, p_display_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v public.dydem_registration_invites%rowtype; registered_email text;
begin
 -- Authorized by GRANT EXECUTE TO service_role alone (no JWT claim required).
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
end $function$;

CREATE OR REPLACE FUNCTION public.dydem_release_registration_invite(p_digest text, p_claim uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
 -- Authorized by GRANT EXECUTE TO service_role alone (no JWT claim required).
 update public.dydem_registration_invites set claim_nonce=null,claimed_at=null
  where token_digest=p_digest and claim_nonce=p_claim and used_at is null;
 return found;
end $function$;


-- Explicitly seal both the functions and the private invite data.
revoke all on function public.dydem_claim_registration_invite(text,uuid,text) from public,anon,authenticated;
revoke all on function public.dydem_finish_registration_invite(text,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.dydem_release_registration_invite(text,uuid) from public,anon,authenticated;
grant execute on function public.dydem_claim_registration_invite(text,uuid,text) to service_role;
grant execute on function public.dydem_finish_registration_invite(text,uuid,uuid,text) to service_role;
grant execute on function public.dydem_release_registration_invite(text,uuid) to service_role;
revoke all on public.dydem_registration_invites from public,anon,authenticated;
grant select,insert,update,delete on public.dydem_registration_invites to service_role;
