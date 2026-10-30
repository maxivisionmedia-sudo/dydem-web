import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";
const url = Deno.env.get("SUPABASE_URL") || "";
const anon = Deno.env.get("SUPABASE_ANON_KEY") || "";
const secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const defaultSite = "https://maxivisionmedia-sudo.github.io/dydem-web/";
const site = [defaultSite, ...(Deno.env.get("DYDEM_SITE_URL") || "").split(",").map(v=>v.trim()).filter(Boolean)];
const origins = new Set(site.map(v=>{try{return new URL(v).origin}catch{return ""}}));
const admin = createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
type PermissionSet={steps:boolean[],add:boolean,delete:boolean};
const emptyPermissions=():PermissionSet=>({steps:[false,false,false,false,false,false,false],add:false,delete:false});
function validPermissions(v:unknown):v is PermissionSet{
 if(!v||typeof v!=="object")return false;
 const p=v as Record<string,unknown>;
 return Array.isArray(p.steps)&&p.steps.length===7&&p.steps.every(x=>typeof x==="boolean")&&typeof p.add==="boolean"&&typeof p.delete==="boolean";
}
function targetRole(value:unknown){return value==="admin"?"admin":value==="custom"?"custom":"viewer"}

serve(async (req:Request)=>{
 const origin=req.headers.get("origin")||"";
 const allowed=origins.has(origin);
 const headers={"Content-Type":"application/json","Access-Control-Allow-Origin":allowed?origin:"null","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"};
 const respond=(status:number,payload:Record<string,unknown>)=>new Response(JSON.stringify(payload),{status,headers});
 if (!allowed) return respond(403,{error:"Origen no autorizado."});
 if (req.method==="OPTIONS") return new Response(null,{status:204,headers});
 if (req.method!=="POST") return respond(405,{error:"Método no permitido"});
 if (!url||!anon||!secret) return respond(503,{error:"Configuración del servidor incompleta"});
 try {
  const token=req.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  if(!token) return respond(401,{error:"Sesión requerida"});
  const client=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error:authError}=await client.auth.getUser(token);
  if(authError||!user)return respond(401,{error:"Sesión inválida"});
  const {data:profile,error:profileError}=await admin.from("profiles").select("role,active").eq("id",user.id).single();
  if(profileError||!profile?.active||profile.role!=="admin")return respond(403,{error:"Solo administradores"});
  const input=await req.json();
  if(input.action==="invite" || input.action==="create-password-user"){
   const email=String(input.email||"").trim().toLowerCase();
   const display=String(input.name||"").trim();
   const role=targetRole(input.role);
   if(role==="custom"&&!validPermissions(input.permissions))return respond(400,{error:"Selecciona los permisos del usuario personalizado."});
   const permissions=role==="custom" ? input.permissions as PermissionSet : emptyPermissions();
   if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||email.length>254||!display||display.length>120)return respond(400,{error:"Correo o nombre inválido"});
   const {count,error:countError}=await admin.from("profiles").select("id",{head:true,count:"exact"}).eq("active",true);
   if(countError)return respond(500,{error:"No se pudieron consultar usuarios"});
   if((count||0)>=5)return respond(409,{error:"Límite de cinco usuarios activos"});
   if(input.action==="create-password-user"){
     // Alta administrativa sin SMTP. El secreto se muestra UNA sola vez al administrador.
     const random=crypto.getRandomValues(new Uint8Array(24));
     const characters="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%";
     const tempPassword="Dy#8-"+Array.from(random,n=>characters[n%characters.length]).join("");
     const {data:created,error:createError}=await admin.auth.admin.createUser({
       email, password:tempPassword, email_confirm:true, user_metadata:{display_name:display}
     });
     if(createError||!created?.user){
       const already=(createError?.code==="email_exists"||/already registered|already exists|already been registered/i.test(createError?.message||""));
       return respond(already?409:400,{code:already?"USER_EXISTS":"CREATE_USER_FAILED",error:already?"Este correo ya está registrado en Supabase.":"No se pudo crear la cuenta: "+(createError?.message||"Error desconocido")});
     }
     const {error:profileSaveError}=await admin.from("profiles").upsert({id:created.user.id,email,display_name:display,role,permissions,active:true},{onConflict:"id"});
     if(profileSaveError){
       // Solo se revierte el usuario creado en esta misma petición.
       await admin.auth.admin.deleteUser(created.user.id);
       return respond(500,{code:"PROFILE_ERROR",error:"No se pudieron guardar los permisos del usuario. No se entregó ninguna contraseña."});
     }
     return respond(200,{ok:true,method:"temporary",temporaryPassword:tempPassword});
   }
   const {data:invite,error:inviteError}=await admin.auth.admin.inviteUserByEmail(email,{data:{display_name:display},redirectTo:defaultSite});
   if(inviteError||!invite?.user){
     const rateLimited=inviteError?.status===429||inviteError?.code==="over_email_send_rate_limit"||/email rate limit/i.test(inviteError?.message||"");
     const unauthorized=inviteError?.code==="email_address_not_authorized"||/email address not authorized/i.test(inviteError?.message||"");
     if(rateLimited)return respond(429,{code:"EMAIL_RATE_LIMIT",error:"Supabase alcanzó el límite de envío de correos. Puedes crear la cuenta con contraseña temporal o configurar SMTP propio."});
     if(unauthorized)return respond(403,{code:"EMAIL_NOT_AUTHORIZED",error:"El servicio de correo de prueba de Supabase no permite enviar a esta dirección. Usa contraseña temporal o configura SMTP propio."});
     return respond(400,{code:"INVITE_ERROR",error:inviteError?.message||"No se pudo invitar"});
   }
   const {error:saveError}=await admin.from("profiles").upsert({id:invite.user.id,email,display_name:display,role,permissions,active:true},{onConflict:"id"});
   if(saveError)return respond(500,{error:"Invitación creada, pero no se pudo asignar el rol. Revísalo en Supabase."});
   return respond(200,{ok:true});
  }
  if(input.action==="set-permissions"){
   const id=String(input.user_id||"");
   const role=targetRole(input.role);
   if(!/^[0-9a-f-]{36}$/i.test(id))return respond(400,{error:"Usuario inválido"});
   if(role==="custom"&&!validPermissions(input.permissions))return respond(400,{error:"Permisos incompletos"});
   if(id===user.id&&role!=="admin")return respond(400,{error:"No puedes quitarte a ti mismo el rol administrador"});
   const {data:target,error:targetError}=await admin.from("profiles").select("id,role,active").eq("id",id).single();
   if(targetError||!target)return respond(404,{error:"Usuario no encontrado"});
   if(target.active&&target.role==="admin"&&role!=="admin"){
     const {count,error:countError}=await admin.from("profiles").select("id",{head:true,count:"exact"}).eq("active",true).eq("role","admin");
     if(countError)return respond(500,{error:"No se pudo validar el número de administradores"});
     if((count||0)<=1)return respond(409,{error:"Debe quedar al menos un administrador activo"});
   }
   const permissions=role==="custom"?input.permissions as PermissionSet:emptyPermissions();
   const {error:updateError}=await admin.from("profiles").update({role,permissions}).eq("id",id);
   if(updateError)return respond(500,{error:"No se pudieron guardar los permisos: "+updateError.message});
   return respond(200,{ok:true});
  }
  if(input.action==="set-active"){
   const id=String(input.user_id||"");
   if(!/^[0-9a-f-]{36}$/i.test(id)||typeof input.active!=="boolean")return respond(400,{error:"Solicitud inválida"});
   if(id===user.id&&input.active===false)return respond(400,{error:"No puedes desactivar tu cuenta"});
   const {data:target,error:targetError}=await admin.from("profiles").select("role,active").eq("id",id).single();
   if(targetError||!target)return respond(404,{error:"Usuario no encontrado"});
   if(!input.active&&target.active&&target.role==="admin"){
    const {count}=await admin.from("profiles").select("id",{head:true,count:"exact"}).eq("role","admin").eq("active",true);
    if((count||0)<=1)return respond(400,{error:"Debe quedar un administrador activo"});
   }
   if(input.active&&!target.active){
    const {count}=await admin.from("profiles").select("id",{head:true,count:"exact"}).eq("active",true);
    if((count||0)>=5)return respond(409,{error:"Límite de cinco usuarios activos"});
   }
   const {error:updateError}=await admin.from("profiles").update({active:input.active}).eq("id",id);
   if(updateError)return respond(500,{error:"No se pudo cambiar el acceso"});
   return respond(200,{ok:true});
  }
  return respond(400,{error:"Acción no reconocida"});
 } catch {return respond(500,{error:"Error del servidor"});}
});