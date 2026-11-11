import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

const url=Deno.env.get("SUPABASE_URL")||"";
const secret=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
const defaultSite="https://maxivisionmedia-sudo.github.io/dydem-web/";
const sites=[defaultSite,...(Deno.env.get("DYDEM_SITE_URL")||"").split(",").map(x=>x.trim()).filter(Boolean)];
const origins=new Set(sites.map(x=>{try{return new URL(x).origin}catch{return ""}}));
const admin=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
const toDigest=async(token:string)=>{
 const bytes=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(token));
 return Array.from(new Uint8Array(bytes),x=>x.toString(16).padStart(2,"0")).join("");
};
const validEmail=(s:string)=>s.length<=254&&/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
const emailText=(email:string)=>email.trim().toLowerCase();

serve(async(req:Request)=>{
 const origin=req.headers.get("origin")||"";
 const headers={"Content-Type":"application/json","Access-Control-Allow-Origin":origins.has(origin)?origin:"null",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS","Cache-Control":"no-store",
  "Vary":"Origin","X-Content-Type-Options":"nosniff"};
 const reply=(code:number,body:Record<string,unknown>)=>new Response(JSON.stringify(body),{status:code,headers});
 if(!origins.has(origin))return reply(403,{error:"Origen no permitido"});
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers});
 if(req.method!=="POST")return reply(405,{error:"Método no permitido"});
 if(!url||!secret)return reply(503,{error:"Servidor de registros no configurado"});
 let body:Record<string,unknown>;
 try{body=await req.json()}catch{return reply(400,{error:"Solicitud mal formada"})}
 const action=String(body.action||"");
 const token=String(body.token||"");
 if(!/^[0-9a-f]{64}$/i.test(token))return reply(400,{error:"El enlace de invitación es inválido"});
 const digest=await toDigest(token.toLowerCase());
 if(action==="inspect"){
  const {data,error}=await admin.from("dydem_registration_invites")
   .select("recipient_email,assigned_role,expires_at,used_at,revoked_at")
   .eq("token_digest",digest).maybeSingle();
  if(error)return reply(503,{error:"No se pudo verificar el enlace"});
  if(!data||data.used_at||data.revoked_at||new Date(data.expires_at).getTime()<=Date.now())
   return reply(410,{error:"El enlace ya fue usado, revocado o ha caducado. Solicita otro al Administrador."});
  return reply(200,{ok:true,email:data.recipient_email||null,
   email_fixed:!!data.recipient_email,role:data.assigned_role,expires_at:data.expires_at});
 }
 if(action!=="register")return reply(400,{error:"Acción desconocida"});
 const name=String(body.name||"").trim(),email=emailText(String(body.email||""));
 const password=String(body.password||"");
 if(name.length<2||name.length>120)return reply(400,{error:"Escribe un nombre de usuario de 2 a 120 caracteres"});
 if(!validEmail(email))return reply(400,{error:"Escribe un correo electrónico válido"});
 if(password.length<12||password.length>128)return reply(400,{error:"La contraseña debe tener entre 12 y 128 caracteres"});
 const claim=crypto.randomUUID();
 const {data:reserved,error:claimError}=await admin.rpc("dydem_claim_registration_invite",{
  p_digest:digest,p_claim:claim,p_email:email
 });
 if(claimError){
  // The underlying problem must be visible to administrators in function
  // logs; do not leak private SQL details or secrets to a public caller.
  console.error("DYDEM invitation claim error",{
   code:claimError.code||"UNKNOWN",message:claimError.message||"Unspecified RPC failure"
  });
  const blocked=claimError.code==="42501"||claimError.code==="PGRST301";
  return reply(503,{code:"INVITATION_RESERVATION_ERROR",
   error:blocked
    ?"DYDEM encontró un error de autorización del servidor. Contacta al Administrador para revisarlo."
    :"No fue posible validar la invitación por un problema del servidor. Puedes reintentar sin perder el enlace."
  });
 }
 if(!reserved?.ok)return reply(409,{error:reserved?.error||"Invitación no disponible"});
 let userId:string|null=null;
 try{
  // The account is not created until the bearer invitation was atomically
  // validated. The Auth trigger starts all new profiles as INACTIVE.
  const {data:created,error:authError}=await admin.auth.admin.createUser({
    email,password,email_confirm:true,user_metadata:{display_name:name}
  });
  if(authError||!created?.user?.id){
   const duplicate=authError?.code==="email_exists"||/already registered|already exists|already been registered|unique/i.test(authError?.message||"");
   return reply(duplicate?409:400,{error:duplicate
    ?"El correo ya tiene una cuenta. Usa otro correo o recupera su acceso."
    :"No se pudo crear la cuenta. Verifica los datos e inténtalo otra vez."});
  }
  userId=created.user.id;
  const {data:completed,error:finishError}=await admin.rpc("dydem_finish_registration_invite",{
    p_digest:digest,p_claim:claim,p_user:userId,p_display_name:name
  });
  if(finishError||completed!==true)throw new Error("No se pudo validar el registro de la cuenta");
  return reply(200,{ok:true,email,name,registered:true,one_time:true});
 }catch(err){
  if(userId)await admin.auth.admin.deleteUser(userId,false);
  return reply(503,{error:"No se pudo finalizar el registro. El enlace seguirá disponible para reintentar."});
 }finally{
  // Only the exact request that claimed the invite can release it.
  await admin.rpc("dydem_release_registration_invite",{p_digest:digest,p_claim:claim});
 }
});
