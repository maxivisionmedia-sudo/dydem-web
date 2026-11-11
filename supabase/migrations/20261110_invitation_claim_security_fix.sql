-- Security definer executes as function owner. Check the signed JWT role,
-- not current_user (which is 'postgres' inside a definer function).
create or replace function public.dydem_claim_registration_invite(
 p_digest text,p_claim uuid,p_email text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $claim$
declare v public.dydem_registration_invites%rowtype;v_total int;
begin
 if coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then
  raise exception 'Solo el servidor puede registrar invitaciones' using errcode='42501';
 end if;
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
end $claim$;

create or replace function public.dydem_finish_registration_invite(
 p_digest text,p_claim uuid,p_user uuid,p_display_name text
) returns boolean language plpgsql security definer set search_path=public,pg_temp as $finish$
declare v public.dydem_registration_invites%rowtype; registered_email text;
begin
 if coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then
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
 if coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then
  raise exception 'Solo el servidor puede liberar invitaciones' using errcode='42501';end if;
 update public.dydem_registration_invites set claim_nonce=null,claimed_at=null
  where token_digest=p_digest and claim_nonce=p_claim and used_at is null;
 return found;
end $release$;
