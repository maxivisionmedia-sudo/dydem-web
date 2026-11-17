// The browser supplies only a project identity and an explicit confirmation.
// File paths and the deletion token always come from checked database functions.
export function createProjectDeletionHandler({createClient,url,anon,secret,origins,now=Date.now}){
 return async req=>{
  const origin=req.headers.get('origin')||'';
  const headers={'Content-Type':'application/json','Access-Control-Allow-Origin':origins.has(origin)?origin:'null',
   'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type',
   'Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin','Cache-Control':'no-store'};
  const reply=(status,data)=>new Response(JSON.stringify(data),{status,headers});
  if(!origins.has(origin))return reply(403,{error:'Origen no autorizado.'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'Método no permitido.'});
  if(!url||!anon||!secret)return reply(503,{error:'Configuración del servidor incompleta.'});
  try{
   const token=req.headers.get('authorization')?.match(/^Bearer\s+(.+)$/i)?.[1];
   if(!token)return reply(401,{error:'Inicia sesión para continuar.'});
   const options={auth:{persistSession:false,autoRefreshToken:false}};
   const scoped=createClient(url,anon,{...options,global:{headers:{Authorization:'Bearer '+token}}});
   const {data:identity,error:authError}=await scoped.auth.getUser(token);
   if(authError||!identity?.user)return reply(401,{error:'La sesión dejó de ser válida.'});
   const {data:isAdmin,error:roleError}=await scoped.rpc('is_dydem_admin');
   if(roleError||isAdmin!==true)return reply(403,{error:'Solo el Administrador puede eliminar proyectos.'});
   let input;try{input=await req.json()}catch{return reply(400,{error:'Solicitud inválida.'})}
   const id=String(input?.project_id||'');
   if(input?.action!=='delete-project'||input?.confirmed!==true||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)||
      typeof input.expected_name!=='string'||!input.expected_name.trim()){
    return reply(400,{error:'Selecciona el proyecto y confirma su eliminación.'});
   }
   const {data:job,error:startError}=await scoped.rpc('dydem_begin_project_delete',{
    pid:id,p_expected_name:input.expected_name,p_confirmed:true});
   if(startError||!job?.ok)return reply(409,{error:startError?.message||'No se pudo iniciar la eliminación.'});
   if(job.done)return reply(200,{ok:true,done:true,project_id:id});
   const admin=createClient(url,secret,options),started=now();
   let removed=0;
   for(let batch=0;batch<10;batch++){
    const {data:step,error:stepError}=await admin.rpc('dydem_project_delete_step',{pid:id,p_token:job.token});
    if(stepError)throw stepError;
    if(step?.done)return reply(200,{ok:true,done:true,project_id:id,files_removed:removed});
    const paths=step?.paths;
    if(!Array.isArray(paths)||!paths.length||paths.length>1000||
       paths.some(path=>typeof path!=='string'||!path.startsWith(id+'/'))){
     throw Error('No se pudo comprobar el alcance de los archivos.');
    }
    const {error:storageError}=await admin.storage.from('activity-attachments').remove(paths);
    if(storageError)throw storageError;
    removed+=paths.length;
    if(now()-started>15000)break;
   }
   return reply(202,{ok:true,done:false,project_id:id,files_removed:removed});
  }catch(err){
   return reply(502,{error:'La eliminación no terminó. El proyecto permanece bloqueado para evitar nuevos cambios. Pulsa «Reintentar eliminación» para continuar. '+(err?.message||'Error de conexión.')});
  }
 };
}
