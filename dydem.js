const names=['Propuesta','Revisión','Autorizado','Avance de Obra','Verificación','Documentado','Completado'];
const KEY='dydem-actividades-v2', OLD='dydem-actividades-v1';
const PROJECT_ID='00000000-0000-4000-8000-00000000d1de';
const fallbackStorage=new Map();
function storeGet(key){try{return localStorage.getItem(key)}catch(e){return fallbackStorage.get(key)??null}}
function storeSet(key,value){fallbackStorage.set(key,value);try{localStorage.setItem(key,value);return true}catch(e){return false}}
function weekInfo(date=new Date()){const d=new Date(Date.UTC(date.getFullYear(),date.getMonth(),date.getDate()));d.setUTCDate(d.getUTCDate()-(d.getUTCDay()||7)+1);const start=new Date(d),end=new Date(d);end.setUTCDate(end.getUTCDate()+6);const th=new Date(d);th.setUTCDate(th.getUTCDate()+3);const year=th.getUTCFullYear(),jan4=new Date(Date.UTC(year,0,4));jan4.setUTCDate(jan4.getUTCDate()-(jan4.getUTCDay()||7)+1);const week=1+Math.round((d-jan4)/604800000),iso=x=>x.toISOString().slice(0,10);return {year,week,start:iso(start),end:iso(end),code:`${year}-S${String(week).padStart(2,'0')}`}}
function assignAnnexes(){const counts={};tasks.forEach(t=>{if(!t.weekCode){t.weekCode='2026-S43';t.weekNumber=43;t.weekStart='2026-10-19';t.weekEnd='2026-10-25'}const wk=t.weekNumber||43;if(!t.annex){counts[t.weekCode]=(counts[t.weekCode]||0)+1;t.annex=`${wk}_${counts[t.weekCode]}`}else counts[t.weekCode]=Math.max(counts[t.weekCode]||0,Number(t.annex.split('_')[1])||0)})}
const fresh=t=>({...t,start:'',end:'',before:'',after:'',reviewers:'',reviewAnnex:'',authorizer:'',progress:0,verification:0,attachments:[],completedDate:'',steps:[false,false,false,false,false,false,false]});
function migrate(t){const n=fresh({id:t.id,title:t.title});n.progress=Math.max(0,Math.min(100,Number(t.progress)||0));return {...n,...t,steps:Array.isArray(t.steps)?t.steps.slice(0,7):n.steps,attachments:Array.isArray(t.attachments)?t.attachments:[],verification:Number(t.verification)||0,progress:n.progress};}
let tasks=[];
const $=id=>document.getElementById(id), esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// Autenticación y datos centralizados: nunca se almacenan contraseñas en DYDEM.
let currentAccount=null,cloud=null,authReady=false,subscription=null,refreshTimer=null;
let commentsByActivity=new Map(),commentDrafts=new Map(),sectionOpen=new Map();
let lastSynced=new Map(),revisions=new Map(),saveBusy=false,savePending=false,refreshQueued=false,refreshDelay=null;
// El enlace puede abrirse en otra pestaña; esta preferencia no autoriza ninguna sesión.
const RECOVERY_PENDING_KEY='dydem-recovery-pending-v1';
const authHashParams=new URLSearchParams(location.hash.replace(/^#/,''));
const authSearchParams=new URLSearchParams(location.search);
let recoverMode=authHashParams.get('type')==='recovery'||authSearchParams.get('type')==='recovery'||
  (storeGet(RECOVERY_PENDING_KEY)==='1'&&(authHashParams.has('access_token')||authSearchParams.has('code')));
function showRecoveryForm(){
 recoverMode=true;
 $('access-title').textContent='Establecer nueva contraseña';
 $('access-help').textContent='Enlace de recuperación: crea una nueva contraseña para tu cuenta DYDEM.';
 $('access-form').hidden=true;$('recover-password').hidden=true;$('use-recovery-code').hidden=true;
 $('otp-container').hidden=true;$('reset-container').hidden=false;$('access-gate').hidden=false;
}
function showLoginForm(message=''){
 recoverMode=false;
 $('access-title').textContent='Acceso a DYDEM en línea';
 $('access-help').textContent='Inicia sesión con el correo electrónico de tu cuenta.';
 $('access-form').hidden=false;$('recover-password').hidden=false;$('use-recovery-code').hidden=false;
 $('otp-container').hidden=true;$('reset-container').hidden=true;
 $('access-gate').hidden=isSignedIn();$('access-error').textContent=message;
}
const isAdmin=()=>!!currentAccount&&currentAccount.role==='admin'&&currentAccount.active;
const isSignedIn=()=>!!currentAccount&&currentAccount.active;
const isCustom=()=>isSignedIn()&&currentAccount.role==='custom';
function emptyPermissions(){return {steps:[false,false,false,false,false,false,false],add:false,delete:false,comment:false}}
function accountPermissions(){const p=currentAccount?.permissions;return p&&Array.isArray(p.steps)&&p.steps.length===7?p:emptyPermissions()}
function canEditStep(i){return isAdmin()||(isCustom()&&accountPermissions().steps[Number(i)]===true)}
function canEditAnyStep(){return names.some((_,i)=>canEditStep(i))}
function canAddActivity(){return isAdmin()||(isCustom()&&accountPermissions().add===true)}
function canDeleteActivity(){return isAdmin()||(isCustom()&&accountPermissions().delete===true)}
function canPostComment(){return isAdmin()||(isCustom()&&accountPermissions().comment===true)}
function stageForField(f){return (['title','start','end','before','after'].includes(f))?0:f==='reviewers'||f==='reviewAnnex'?1:f==='authorizer'?2:f==='progress'?3:f==='verification'?4:f==='attachments'?5:f==='completedDate'?6:-1}
function permissionChooser(prefix,p){
 const perms=p&&Array.isArray(p.steps)?p:emptyPermissions();
 return '<div class="permission-choices">'+names.map((name,i)=>
  `<label class="permission-item"><input type="checkbox" data-custom-step="${i}" ${perms.steps[i]?'checked':''}><span><b>${i+1}. ${esc(name)}</b>${i===0?'<small>Descripción, fechas y dependencias</small>':''}</span></label>`).join('')+
 `<label class="permission-item"><input type="checkbox" data-custom-action="add" ${perms.add?'checked':''}><span><b>Agregar actividades</b></span></label>
 <label class="permission-item"><input type="checkbox" data-custom-action="delete" ${perms.delete?'checked':''}><span><b>Eliminar actividades</b></span></label>
 <label class="permission-item"><input type="checkbox" data-custom-action="comment" ${perms.comment?'checked':''}><span><b>Publicar comentarios</b><small>Sin este permiso puede leer los comentarios existentes</small></span></label></div>`;
}
function readPermissions(root){return {steps:names.map((_,i)=>!!root.querySelector('[data-custom-step="'+i+'"]')?.checked),add:!!root.querySelector('[data-custom-action="add"]')?.checked,delete:!!root.querySelector('[data-custom-action="delete"]')?.checked,comment:!!root.querySelector('[data-custom-action="comment"]')?.checked}}
function roleLabel(role){return role==='admin'?'Administrador':role==='custom'?'Personalizado':'Visualizador'}
function permissionSummary(p){if(!p?.steps)return 'Sin etapas concedidas';const a=p.steps.map((v,i)=>v?names[i]:null).filter(Boolean);if(p.add)a.push('Agregar');if(p.delete)a.push('Eliminar');if(p.comment)a.push('Publicar comentarios');return a.length?a.join(', '):'Solo lectura y ver comentarios'}

function syncState(message,error=false,busy=false){const el=$('sync-state');if(!el)return;el.textContent=message;el.classList.toggle('is-error',error);el.classList.toggle('is-busy',busy)}
function messageError(err){return (err&&err.message)||String(err||'Error desconocido')}
async function edgeErrorMessage(err){
 const response=err?.context;
 if(response&&typeof response.json==='function'){
  try{
   const payload=await response.clone().json();
   if(payload?.error)return String(payload.error);
  }catch(_){}
  if(response.status===429)return 'Supabase ha limitado el envío de correos. Prueba la opción de contraseña temporal o configura SMTP propio.';
  return 'Error de servidor (HTTP '+response.status+').';
 }
 return messageError(err);
}
function connectionConfig(){const cfg=window.DYDEM_CONFIG||{};if(!cfg.url||!/^https:\/\/[^/]+/.test(cfg.url)||!cfg.anonKey||cfg.anonKey.includes('REEMPLAZAR')||!window.supabase?.createClient)return null;return cfg}
function showSetupError(){const el=$('access-error');$('access-help').textContent='La instalación todavía no está conectada a Supabase.';el.textContent='Configura site/config.js con la URL y la clave pública del proyecto. Después publica el sitio por HTTPS. Consulta INSTRUCCIONES.md.';$('access-submit').disabled=true}
function enterAccount(profile){currentAccount={...profile,name:profile.display_name||profile.email||'Usuario'};$('add').hidden=!canAddActivity();$('save').hidden=!canEditAnyStep();document.body.classList.add('signed-in');document.body.classList.toggle('viewer-mode',!isAdmin()&&!isCustom());document.body.classList.toggle('custom-mode',isCustom());if(recoverMode)showRecoveryForm();else {$('access-gate').hidden=true;$('reset-container').hidden=true;}$('session-label').textContent=currentAccount.name+' · '+roleLabel(currentAccount.role);$('manage-users').hidden=!isAdmin();$('user-management').hidden=true;render();}
async function loadAccount(){const {data:sessionData,error:sessionError}=await cloud.auth.getSession();if(sessionError)throw sessionError;const user=sessionData.session?.user;if(!user){await leaveAccount(false);return}const {data:profile,error}=await cloud.from('profiles').select('id,email,display_name,role,permissions,active').eq('id',user.id).single();if(error||!profile||!profile.active){await cloud.auth.signOut();throw Error('Esta cuenta no tiene acceso activo a DYDEM. Consulta a un administrador.')}enterAccount(profile);await reloadActivities(true);startRealtime();if(isAdmin()&&!recoverMode)setTimeout(startup,150)}
async function leaveAccount(signout=true){if(refreshTimer){clearInterval(refreshTimer);refreshTimer=null}if(subscription&&cloud){await cloud.removeChannel(subscription);subscription=null}if(signout&&cloud)await cloud.auth.signOut();currentAccount=null;tasks=[];commentsByActivity.clear();pendingAttachmentIntents.clear();pendingFileRegistrations.clear();commentDrafts.clear();lastSynced.clear();revisions.clear();document.body.classList.remove('signed-in','viewer-mode','custom-mode');$('access-gate').hidden=false;$('user-management').hidden=true;$('access-pass').value='';render();syncState('Sin sesión')}
function isDirty(){return tasks.some(t=>JSON.stringify(t)!==lastSynced.get(Number(t.id)))}
async function reloadComments(){
 if(!isSignedIn())return;
 const {data,error}=await cloud.from('activity_comments')
  .select('id,activity_id,body,created_at,author_id,author_name')
  .eq('project_id',PROJECT_ID).order('created_at',{ascending:true}).order('id',{ascending:true});
 if(error)throw error;
 const next=new Map();
 for(const item of (data||[])){
  const id=Number(item.activity_id);
  if(!next.has(id))next.set(id,[]);
  next.get(id).push(item);
 }
 commentsByActivity=next;
}
async function reloadActivities(force=false){if(!isSignedIn())return;if((saveBusy||isDirty())&&!force){refreshQueued=true;return}syncState('Actualizando…',false,true);try{await reconcileAttachmentIntents()}catch(err){console.warn('Pendientes de Documentado:',messageError(err))}const {data,error}=await cloud.from('activities').select('id,data,revision').eq('project_id',PROJECT_ID).is('deleted_at',null).order('id',{ascending:true});if(error){syncState('Error de conexión',true);throw error}await reloadComments();tasks=(data||[]).map(r=>migrate({...r.data,id:Number(r.id)}));if(!collapsePreferencesInitialized){const saved=storeGet(COLLAPSE_KEY);if(saved===null){tasks.forEach(t=>collapsedActivities.add(String(t.id)));persistCollapsed()}collapsePreferencesInitialized=true}lastSynced=new Map(tasks.map(t=>[Number(t.id),JSON.stringify(t)]));revisions=new Map(data.map(r=>[Number(r.id),r.revision]));render();syncState('Actualizado');refreshQueued=false}
function scheduleCloudRefresh(){if(refreshDelay)clearTimeout(refreshDelay);refreshDelay=setTimeout(()=>{refreshDelay=null;reloadActivities().catch(e=>syncState('No se pudo sincronizar',true))},450)}
function startRealtime(){if(subscription){cloud.removeChannel(subscription);subscription=null}subscription=cloud.channel('dydem-obra-shared').on('postgres_changes',{event:'*',schema:'public',table:'activities',filter:`project_id=eq.${PROJECT_ID}`},()=>scheduleCloudRefresh()).on('postgres_changes',{event:'INSERT',schema:'public',table:'activity_comments',filter:`project_id=eq.${PROJECT_ID}`},()=>scheduleCloudRefresh()).on('postgres_changes',{event:'DELETE',schema:'public',table:'activity_comments'},()=>scheduleCloudRefresh()).subscribe();if(refreshTimer)clearInterval(refreshTimer);refreshTimer=setInterval(()=>{if(isSignedIn())reloadActivities().catch(()=>syncState('Error de actualización',true))},15000)}
async function save(){if(!canEditAnyStep())return;savePending=true;if(saveBusy)return;saveBusy=true;syncState('Guardando…',false,true);
 try{while(savePending){savePending=false;const changed=tasks.filter(t=>JSON.stringify(t)!==lastSynced.get(Number(t.id)));
  for(const t of changed){const id=Number(t.id),expected=revisions.get(id);if(expected===undefined)throw Error('Actividad sin versión de servidor: '+id);const sent=JSON.stringify(t);const {data,error}=await cloud.rpc(isAdmin()?'update_activity':'update_activity_custom',{p_id:id,p_expected_revision:expected,p_data:JSON.parse(sent)});if(error)throw error;revisions.set(id,data.revision);lastSynced.set(id,JSON.stringify(migrate(data.data)));}
 }}catch(e){savePending=false;const msg=messageError(e);syncState('Cambios pendientes: error',true);alert('No se pudo confirmar el guardado en el servidor. Los cambios siguen visibles en esta pestaña y puedes reintentar con «Guardar cambios». No cierres la página sin guardarlos. Detalle: '+msg);return}finally{saveBusy=false}
 syncState('Guardado');if(refreshQueued)reloadActivities().catch(()=>syncState('Sincronización pendiente',true));
}
$('access-form').addEventListener('submit',async e=>{e.preventDefault();if(!cloud)return;const btn=$('access-submit');btn.disabled=true;$('access-error').textContent='';try{const {error}=await cloud.auth.signInWithPassword({email:$('access-user').value.trim(),password:$('access-pass').value});if(error)throw error;await loadAccount()}catch(err){$('access-error').textContent='No se pudo iniciar sesión: '+messageError(err)}finally{btn.disabled=false;$('access-pass').value=''}});
$('signout').onclick=()=>{if((isDirty()||saveBusy)&&!confirm('Hay cambios que aún no se han guardado. ¿Cerrar sesión y descartarlos?'))return;leaveAccount().catch(e=>alert(messageError(e)))};
$('reload-cloud').onclick=()=>{if((saveBusy||isDirty())&&!confirm('Hay cambios aún no confirmados. ¿Descartar los cambios locales y actualizar desde el servidor?'))return;reloadActivities(true).catch(e=>alert('Error: '+messageError(e)))};
$('recover-password').onclick=async()=>{
 if(!cloud)return;const email=$('access-user').value.trim();
 if(!email){$('access-error').textContent='Escribe primero tu correo electrónico.';return}
 try{
  const {error}=await cloud.auth.resetPasswordForEmail(email,{redirectTo:location.origin+location.pathname});
  if(error)throw error;
  storeSet(RECOVERY_PENDING_KEY,'1');$('otp-email').value=email;
  $('access-error').textContent='Correo solicitado. Abre el enlace más reciente; si recibiste un código numérico, selecciona «Tengo un código de recuperación».';
 }catch(e){$('access-error').textContent=messageError(e)}
};
$('use-recovery-code').onclick=()=>{
 $('otp-container').hidden=false;$('otp-email').value=$('otp-email').value||$('access-user').value.trim();
 $('access-error').textContent='Introduce el código numérico que llegó a tu correo. Si recibiste un enlace, ábrelo en lugar de escribir un código.';
};
$('otp-form').onsubmit=async e=>{
 e.preventDefault();if(!cloud)return;
 const email=$('otp-email').value.trim(),token=$('otp-token').value.replace(/\s+/g,'');
 if(!email||!/^\d{6,8}$/.test(token)){$('access-error').textContent='Introduce el correo y el código numérico completo.';return}
 const btn=$('verify-otp');btn.disabled=true;
 try{
  const {error}=await cloud.auth.verifyOtp({email,token,type:'recovery'});
  if(error)throw error;
  showRecoveryForm();$('access-error').textContent='Código validado. Ahora crea una contraseña nueva.';
 }catch(err){$('access-error').textContent='No se pudo validar el código: '+messageError(err)}
 finally{btn.disabled=false}
};
$('reset-form').onsubmit=async e=>{
 e.preventDefault();if(!cloud)return;
 const password=$('reset-password').value;
 if(password.length<10){$('access-error').textContent='Utiliza al menos 10 caracteres.';return}
 const btn=$('set-new-password');btn.disabled=true;$('access-error').textContent='Actualizando contraseña…';
 try{
  const {data:{session},error:sessionError}=await cloud.auth.getSession();
  if(sessionError)throw sessionError;
  if(!session)throw Error('El enlace ya expiró o no se validó. Vuelve a solicitar la recuperación e ingresa desde el correo más reciente.');
  const {error}=await cloud.auth.updateUser({password});if(error)throw error;
  storeSet(RECOVERY_PENDING_KEY,'0');$('reset-password').value='';
  history.replaceState(null,'',location.pathname);
  const {error:signoutError}=await cloud.auth.signOut();
  if(signoutError)throw Error('Se cambió la contraseña, pero no se pudo cerrar la sesión automáticamente. Cierra sesión y vuelve a entrar.');
  await leaveAccount(false);
  showLoginForm('Contraseña actualizada correctamente. Inicia sesión con tu nueva contraseña.');
 }catch(error){$('access-error').textContent=messageError(error)}
 finally{btn.disabled=false}
};
$('change-password').onclick=()=>{
 if(!isSignedIn())return;
 showRecoveryForm();$('access-help').textContent='Sesión activa: introduce una nueva contraseña de al menos diez caracteres.';$('access-error').textContent='';
};
$('cancel-password').onclick=()=>{storeSet(RECOVERY_PENDING_KEY,'0');showLoginForm();};
async function showUsers(){
 if(!isAdmin())return;
 const {data,error}=await cloud.from('profiles').select('id,email,display_name,role,permissions,active').order('created_at',{ascending:true});
 if(error){$('user-error').textContent=messageError(error);return}
 $('user-list').innerHTML=(data||[]).map(a=>{
  const self=a.id===currentAccount.id, p=a.permissions||emptyPermissions();
  const opts=['viewer','custom','admin'].map(r=>`<option value="${r}" ${r===a.role?'selected':''}>${roleLabel(r)}</option>`).join('');
  return `<div class="user-entry">
   <div class="user-summary"><b>${esc(a.display_name||a.email)}</b><span>${esc(a.email)} · ${roleLabel(a.role)} · ${a.active?'Activo':'Desactivado'}</span>${a.role==='custom'?`<small>${esc(permissionSummary(p))}</small>`:''}</div>
   <div class="user-actions">${self?'<span class="muted">(sesión actual)</span>':`<button class="btn secondary" type="button" data-toggle-user="${esc(a.id)}" data-active="${a.active?'true':'false'}">${a.active?'Desactivar':'Reactivar'}</button><button class="btn secondary" type="button" data-configure-user="${esc(a.id)}">Configurar permisos</button>`}</div>
   ${self?'':`<div class="user-permissions-editor" data-editor-user="${esc(a.id)}" hidden>
    <label>Tipo de permiso<select data-edit-role>${opts}</select></label>
    <fieldset class="permission-panel" data-edit-custom ${a.role==='custom'?'':'hidden'}><legend>Permitir modificar estas etapas</legend>${permissionChooser(a.id,p)}</fieldset>
    <div class="user-actions"><button class="btn" type="button" data-save-user-permissions="${esc(a.id)}">Guardar permisos</button><button class="btn secondary" type="button" data-cancel-user-permissions="${esc(a.id)}">Cancelar</button></div>
   </div>`}
  </div>`;
 }).join('');
}
$('manage-users').onclick=()=>{if(!isAdmin())return;$('user-management').hidden=!$('user-management').hidden;if(!$('user-management').hidden)showUsers()};
$('user-create').onsubmit=async e=>{
 e.preventDefault();if(!isAdmin())return;
 const btn=e.submitter||$('user-create').querySelector('button[type="submit"]');
 const temporary=$('new-method').value==='temporary';
 const role=$('new-role').value;const permissions=role==='custom'?readPermissions($('new-custom-permissions')):emptyPermissions();
 btn.disabled=true;
 $('temporary-access').hidden=true;
 $('temporary-password').value='';
 $('user-error').textContent=temporary?'Creando cuenta…':'Enviando invitación…';
 try{
  const {data,error}=await cloud.functions.invoke('manage-users',{
   body:{action:temporary?'create-password-user':'invite',email:$('new-user').value.trim(),name:$('new-name').value.trim(),role,permissions}
  });
  if(error)throw Error(await edgeErrorMessage(error));
  if(data?.error)throw Error(data.error);
  if(temporary){
   if(!data?.temporaryPassword)throw Error('La cuenta fue creada, pero la contraseña temporal no se recibió. Consulta el administrador de Supabase.');
   $('temporary-password').value=data.temporaryPassword;
   $('temporary-access').hidden=false;
   $('user-error').textContent='Cuenta creada. Copia la contraseña temporal y compártela por un canal privado; no se enviará por correo.';
  }else{
   $('user-error').textContent='Invitación enviada. La persona deberá aceptar el correo y establecer su contraseña.';
  }
  $('user-create').reset();$('new-custom-permissions').hidden=true;
  await showUsers();
 }catch(err){
  $('user-error').textContent='No se pudo '+(temporary?'crear el acceso':'enviar la invitación')+': '+messageError(err);
 }finally{btn.disabled=false}
};
$('copy-temporary-password').onclick=async()=>{
 const input=$('temporary-password');if(!input.value)return;
 try{
  await navigator.clipboard.writeText(input.value);
  $('copy-temporary-password').textContent='Copiada';
 }catch(err){
  input.select();
  $('user-error').textContent='Selecciona la contraseña temporal y cópiala con Ctrl+C.';
 }
};
$('new-custom-permissions').insertAdjacentHTML('beforeend',permissionChooser('new',emptyPermissions()));
$('new-role').onchange=()=>{$('new-custom-permissions').hidden=$('new-role').value!=='custom'};
$('user-list').addEventListener('change',e=>{
 const sel=e.target.closest('select[data-edit-role]');
 if(sel){const edit=sel.closest('[data-editor-user]');edit.querySelector('[data-edit-custom]').hidden=sel.value!=='custom'}
});
$('user-list').onclick=async e=>{
 const toggle=e.target.closest('[data-toggle-user]');
 const config=e.target.closest('[data-configure-user]');
 const cancel=e.target.closest('[data-cancel-user-permissions]');
 const submit=e.target.closest('[data-save-user-permissions]');
 if(!isAdmin())return;
 if(config){const box=$('user-list').querySelector('[data-editor-user="'+config.dataset.configureUser+'"]');if(box)box.hidden=!box.hidden;return}
 if(cancel){const box=$('user-list').querySelector('[data-editor-user="'+cancel.dataset.cancelUserPermissions+'"]');if(box)box.hidden=true;return}
 if(submit){
  const id=submit.dataset.saveUserPermissions,box=$('user-list').querySelector('[data-editor-user="'+id+'"]');
  if(!box)return;
  const role=box.querySelector('[data-edit-role]').value;
  const permissions=role==='custom'?readPermissions(box.querySelector('[data-edit-custom]')):emptyPermissions();
  if(!confirm('¿Guardar los permisos de este usuario? Los cambios se aplicarán al actualizar su sesión.'))return;
  submit.disabled=true;$('user-error').textContent='Guardando permisos…';
  try{
   const {data,error}=await cloud.functions.invoke('manage-users',{body:{action:'set-permissions',user_id:id,role,permissions}});
   if(error)throw Error(await edgeErrorMessage(error));
   if(data?.error)throw Error(data.error);
   $('user-error').textContent='Permisos actualizados correctamente.';
   await showUsers();
  }catch(err){$('user-error').textContent='No se pudieron guardar los permisos: '+messageError(err)}
  finally{submit.disabled=false}
  return;
 }
 if(toggle){
  const activate=toggle.dataset.active!=='true';
  if(!confirm((activate?'¿Reactivar':'¿Desactivar')+' el acceso de este usuario?'))return;
  toggle.disabled=true;
  try{
   const {data,error}=await cloud.functions.invoke('manage-users',{body:{action:'set-active',user_id:toggle.dataset.toggleUser,active:activate}});
   if(error)throw Error(await edgeErrorMessage(error));
   if(data?.error)throw Error(data.error);
   await showUsers()
  }catch(err){$('user-error').textContent=messageError(err)}
  finally{toggle.disabled=false}
 }
};
async function initializeOnline(){
 const cfg=connectionConfig();if(!cfg){showSetupError();return}
 cloud=window.supabase.createClient(cfg.url,cfg.anonKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
 // Preparar interfaz antes de que el SDK procese el fragmento #access_token.
 if(recoverMode)showRecoveryForm();
 cloud.auth.onAuthStateChange((event)=>{
  if(event==='PASSWORD_RECOVERY'){
   showRecoveryForm();$('access-error').textContent='Enlace validado. Escribe tu nueva contraseña.';
  }
  if(event==='SIGNED_IN'&&recoverMode)showRecoveryForm();
  if(event==='SIGNED_OUT'&&currentAccount)void leaveAccount(false);
 });
 try{
  await loadAccount();
  if(recoverMode){
   const {data:{session}}=await cloud.auth.getSession();
   showRecoveryForm();
   $('access-error').textContent=session?'Enlace validado. Ahora establece tu nueva contraseña.':'No se pudo validar el enlace. Si expiró, vuelve al inicio y solicita uno nuevo.';
  }
  syncState('Conectado');
 }catch(e){$('access-error').textContent=messageError(e);syncState('Error de acceso',true)}
}
const task=id=>tasks.find(t=>t.id===Number(id));
function status(t){return t.steps[6]?'Terminado':Number(t.progress)>0?'En proceso':'Por empezar'}
function selectOptions(self,selected){return '<option value="">Ninguna</option>'+tasks.filter(t=>t.id!==self).map(t=>`<option value="${t.id}" ${String(selected)===String(t.id)?'selected':''}>#${t.id} — ${esc(t.title.slice(0,65))}</option>`).join('')}

function timelineData(){
 const valid=x=>/^\d{4}-\d{2}-\d{2}$/.test(x||'')&&!isNaN(Date.parse(x+'T00:00:00Z'));
 const day=x=>Math.round(Date.parse(x+'T00:00:00Z')/86400000);
 const wi=weekInfo(),values=tasks.flatMap(t=>[t.start,t.end,t.completedDate]).filter(valid).concat([wi.start,wi.end]).map(day);
 let lo=Math.min(...values),hi=Math.max(...values);
 lo-=(new Date(lo*86400000).getUTCDay()+6)%7;
 hi+=6-(new Date(hi*86400000).getUTCDay()+6)%7;
 const weeks=[];for(let d=lo;d<=hi;d+=7){const dt=new Date(d*86400000),w=weekInfo(new Date(dt.getUTCFullYear(),dt.getUTCMonth(),dt.getUTCDate()));weeks.push({d,label:'S'+w.week+' · '+w.start.slice(5)+'–'+w.end.slice(5)})}
 return {valid,day,lo,hi,weeks,total:hi-lo+1};
}
function statusDot(t){const st=status(t);const color=st==='Terminado'?'#18a566':st==='En proceso'?'#f2c230':'#e34848';return `<span class="activity-status-dot" style="background:${color}" title="${st}" aria-label="Estado: ${st}"></span>`}

function commentsFor(id){return commentsByActivity.get(Number(id))||[]}
function displayCommentTime(value){
 const date=new Date(value);
 return isNaN(date.getTime())?'':date.toLocaleString('es-MX',{year:'numeric',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
}
function commentListHTML(t){
 const comments=commentsFor(t.id);
 if(!comments.length)return '<div class="comment-empty">Todavía no hay comentarios.</div>';
 return `<div class="comment-list">${comments.map(c=>`<article class="comment-item"><span class="comment-avatar" aria-hidden="true">👤</span><div class="comment-bubble"><div class="comment-meta"><b>${esc(c.author_name||'Usuario')}</b><time>${esc(displayCommentTime(c.created_at))}</time>${isAdmin()?`<button type="button" class="comment-delete" data-delete-comment="${Number(c.id)}" data-comment-activity="${Number(t.id)}" aria-label="Eliminar comentario" title="Eliminar este comentario">Eliminar</button>`:""}</div><div class="comment-text">${esc(c.body)}</div></div></article>`).join('')}</div>`;
}
function sectionIsOpen(id,name){return sectionOpen.get(name+':'+id)!==false}
function commentsSection(t){
 const open=sectionIsOpen(t.id,'comments')?' open':'';
 const composer=canPostComment()?`<form class="comment-form" data-comment-form="${t.id}"><label class="comment-input-label" for="comment-input-${t.id}">Añade un comentario</label><div class="comment-compose"><textarea id="comment-input-${t.id}" data-comment-input="${t.id}" maxlength="2000" rows="2" placeholder="Añade un comentario" required>${esc(commentDrafts.get(Number(t.id))||'')}</textarea><button type="submit" class="btn comment-submit" aria-label="Publicar comentario de la actividad ${esc(t.annex)}" title="Publicar comentario">↑</button></div><span class="comment-feedback" data-comment-feedback="${t.id}" role="status"></span></form>`:`<p class="comment-readonly-note">Puedes consultar los comentarios. Tu permiso actual no permite publicar mensajes.</p>`;
 return `<details class="viewer-section comments-section" data-activity-section="${t.id}" data-section-kind="comments"${open}><summary>Comentarios <span class="comment-count">${commentsFor(t.id).length}</span></summary><div class="viewer-section-inner">${composer}<div data-comment-feed="${t.id}">${commentListHTML(t)}</div></div></details>`;
}
function viewerLinkedActivity(value){
 if(!value)return 'Ninguna';
 const linked=task(value);
 return linked?`${linked.annex} · ${linked.title}`:`Actividad ${value}`;
}

const MAX_ATTACHMENT_BYTES=500*1024*1024;
// Límite actual comprobado del bucket en Supabase: 50 MiB. Aumentarlo requiere configuración del plan.
const CURRENT_STORAGE_LIMIT_BYTES=50*1024*1024;
const attachmentAssets=new Map();
let attachmentPreviewSequence=0;
let attachmentUploadBusy=false;
const attachmentPreviewUrls=new Set();
function revokeAttachmentPreviewUrls(){
 for(const url of attachmentPreviewUrls)URL.revokeObjectURL(url);
 attachmentPreviewUrls.clear();
}
function attachmentSize(n){return n>1024*1024?(n/(1024*1024)).toFixed(1)+' MB':n>1024?(n/1024).toFixed(0)+' KB':(n||0)+' bytes'}
function attachmentActions(t,a){
 const kind=attachmentFileKind(a);
 const types={
  image:{icon:'🖼️',label:'Imagen'},
  heic:{icon:'📷',label:'Imagen HEIC o HEIF'},
  pdf:{icon:'📕',label:'Documento PDF'},
  video:{icon:'🎞️',label:'Video'},
  audio:{icon:'🎵',label:'Audio'},
  text:{icon:'📝',label:'Documento de texto'},
  unsupported:{icon:'📎',label:'Archivo adjunto'}
 };
 const type=types[kind]||types.unsupported;
 return `<button type="button" class="attachment-file attachment-file-${kind}" data-preview="${esc(a.id)}" data-id="${t.id}" aria-label="Abrir ${esc(type.label)}: ${esc(a.name)}" title="Abrir archivo: ${esc(a.name)}"><span class="attachment-file-icon" aria-hidden="true">${type.icon}</span><span class="attachment-file-name">${esc(a.name)}</span></button>`;
}
function attachmentFileKind(meta){
 const name=String(meta?.name||'').toLowerCase(),type=String(meta?.type||'').toLowerCase();
 if(/\.hei[cf]$/.test(name)||/^image\/hei[cf](?:-sequence)?$/.test(type))return 'heic';
 if(type.startsWith('image/')||/\.(png|jpe?g|gif|webp|bmp|avif|svg)$/.test(name))return 'image';
 if(type==='application/pdf'||/\.pdf$/.test(name))return 'pdf';
 if(type.startsWith('video/')||/\.(mp4|mov|webm|m4v|ogg|ogv)$/.test(name))return 'video';
 if(type.startsWith('audio/')||/\.(mp3|m4a|wav|opus|flac)$/.test(name))return 'audio';
 if((type.startsWith('text/')||/\.(txt|csv|md|log|json|xml)$/.test(name))&&(!meta.size||meta.size<=1024*1024))return 'text';
 return 'unsupported';
}
function ensureCloudFile(meta){
 if(!isSignedIn())throw Error('Inicia sesión para acceder a los archivos');
 if(!meta?.path)throw Error('Este anexo no está disponible en la nube. Solicita que se vuelva a cargar el original.');
 if(!meta.path.startsWith(PROJECT_ID+'/'))throw Error('La referencia del archivo no pertenece a esta obra');
}
async function signedAttachmentUrl(meta){
 ensureCloudFile(meta);
 const {data,error}=await cloud.storage.from('activity-attachments').createSignedUrl(meta.path,600);
 if(error||!data?.signedUrl)throw error||Error('No se pudo generar el acceso temporal al archivo');
 return data.signedUrl;
}
function loadAttachmentLibrary(name,src){
 if(window[name])return Promise.resolve(window[name]);
 if(attachmentAssets.has(name))return attachmentAssets.get(name);
 const loader=new Promise((resolve,reject)=>{
  const script=document.createElement('script');
  script.src=src;script.async=true;
  script.onload=()=>window[name]?resolve(window[name]):reject(Error('El visor no está disponible'));
  script.onerror=()=>reject(Error('No se pudo cargar el componente de vista previa. Puedes descargar el archivo.'));
  document.head.appendChild(script);
 });
 attachmentAssets.set(name,loader);
 loader.catch(()=>attachmentAssets.delete(name));
 return loader;
}
function closeAttachmentPreview(){
 attachmentPreviewSequence++;
 const box=$('attachment-preview');
 if(!box)return;
 box.querySelectorAll('video,audio').forEach(el=>{try{el.pause();el.removeAttribute('src');el.load()}catch(_){}});
 $('attachment-preview-body').replaceChildren();
 revokeAttachmentPreviewUrls();
 box.hidden=true;
}
async function previewAttachment(t,meta){
 if(!t||!meta)return;
 const request=++attachmentPreviewSequence;
 const modal=$('attachment-preview'),body=$('attachment-preview-body'),note=$('attachment-preview-note');
 modal.hidden=false;
 $('attachment-preview-title').textContent=meta.name||'Archivo adjunto';
 $('attachment-preview-download').dataset.download=meta.id;
 $('attachment-preview-download').dataset.id=String(t.id);
 body.replaceChildren();
 revokeAttachmentPreviewUrls();
 note.textContent='Cargando vista previa…';
 const showFailure=()=>{if(request!==attachmentPreviewSequence)return;body.replaceChildren();const p=document.createElement('p');p.className='preview-unavailable';p.textContent='No se puede abrir una vista previa de este archivo. Puedes descargarlo.';body.appendChild(p);note.textContent='Vista previa no disponible.'};
 const kind=attachmentFileKind(meta);
 if(kind==='unsupported'){showFailure();return}
 try{
  const url=await signedAttachmentUrl(meta);
  if(request!==attachmentPreviewSequence)return;
  if(kind==='image'){
   const img=document.createElement('img');img.className='preview-image';img.alt='Vista previa de '+meta.name;
   img.onerror=showFailure;img.src=url;body.appendChild(img);
   note.textContent='Imagen original. Archivo disponible para descargar.';
  }else if(kind==='heic'){
   // Safari puede mostrar HEIC de manera nativa. Otros navegadores necesitan
   // convertir una copia temporal a JPEG; la descarga conserva el HEIC original.
   const img=document.createElement('img');img.className='preview-image';img.alt='Vista previa de '+meta.name;
   let attemptedConversion=false;
   img.onload=()=>{
    if(request!==attachmentPreviewSequence)return;
    note.textContent=attemptedConversion?
     'Vista previa convertida a JPEG. Al descargar se conserva el HEIC/HEIF original.':
     'Imagen HEIC/HEIF. Puedes descargar el archivo original.';
   };
   img.onerror=async()=>{
    if(request!==attachmentPreviewSequence)return;
    if(attemptedConversion){showFailure();return}
    attemptedConversion=true;
    note.textContent='Preparando vista previa HEIC/HEIF…';
    try{
     const converter=await loadAttachmentLibrary('heic2any','https://cdn.jsdelivr.net/npm/heic2any@0.0.4/dist/heic2any.min.js');
     if(request!==attachmentPreviewSequence)return;
     const original=await getFile(meta);
     if(request!==attachmentPreviewSequence)return;
     const converted=await converter({blob:original,toType:'image/jpeg',quality:0.85});
     if(request!==attachmentPreviewSequence)return;
     const image=Array.isArray(converted)?converted[0]:converted;
     if(!(image instanceof Blob))throw Error('No se pudo interpretar la imagen HEIC');
     const convertedURL=URL.createObjectURL(image);
     if(request!==attachmentPreviewSequence){URL.revokeObjectURL(convertedURL);return}
     attachmentPreviewUrls.add(convertedURL);
     img.src=convertedURL;
    }catch(error){
     if(request!==attachmentPreviewSequence)return;
     showFailure();
     note.textContent='No se puede abrir el HEIC/HEIF en este dispositivo: '+messageError(error)+'. Puedes descargar el original.';
    }
   };
   body.appendChild(img);
   img.src=url;
   note.textContent='Abriendo imagen HEIC/HEIF…';
  }else if(kind==='pdf'){
   const lib=await loadAttachmentLibrary('pdfjsLib','https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js');
   if(request!==attachmentPreviewSequence)return;
   lib.GlobalWorkerOptions.workerSrc='https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.worker.min.js';
   const pdf=await lib.getDocument({url,rangeChunkSize:131072}).promise;
   try{
    if(request!==attachmentPreviewSequence)return;
    const page=await pdf.getPage(1),base=page.getViewport({scale:1});
    const scale=Math.min(1.75,Math.max(.35,850/base.width));
    const viewport=page.getViewport({scale}),canvas=document.createElement('canvas');
    const ratio=Math.min(window.devicePixelRatio||1,1.5);
    canvas.width=Math.round(viewport.width*ratio);canvas.height=Math.round(viewport.height*ratio);
    canvas.style.width=Math.round(viewport.width)+'px';canvas.style.height=Math.round(viewport.height)+'px';
    canvas.className='preview-pdf-canvas';
    await page.render({canvasContext:canvas.getContext('2d'),viewport,transform:ratio!==1?[ratio,0,0,ratio,0,0]:null}).promise;
    if(request===attachmentPreviewSequence){body.replaceChildren(canvas);note.textContent='Primera página del PDF. Descarga el archivo para consultar todas las páginas.'}
   }finally{await pdf.destroy()}
  }else if(kind==='video'){
   const video=document.createElement('video');
   video.controls=true;video.playsInline=true;video.preload='metadata';
   video.className='preview-video';video.src=url;
   video.onseeking=()=>{if(video.currentTime>30)video.currentTime=30};
   video.ontimeupdate=()=>{if(video.currentTime>=30){video.pause();video.currentTime=30;note.textContent='Vista previa finalizada (30 segundos). Descarga el video para verlo completo.'}};
   video.onplay=()=>{if(video.currentTime>=30)video.currentTime=0};
   video.onerror=showFailure;
   body.appendChild(video);
   note.textContent='Video: reproducción limitada a los primeros 30 segundos.';
  }else if(kind==='audio'){
   const audio=document.createElement('audio');audio.controls=true;audio.preload='metadata';audio.src=url;audio.onerror=showFailure;body.appendChild(audio);
   note.textContent='Audio disponible para escuchar o descargar.';
  }else if(kind==='text'){
   const file=await getFile(meta);
   if(request!==attachmentPreviewSequence)return;
   if(file.size>1024*1024){showFailure();return}
   const pre=document.createElement('pre');pre.className='preview-text';pre.textContent=(await file.text()).slice(0,25000);body.appendChild(pre);
   note.textContent='Vista previa de texto (primeros 25,000 caracteres).';
  }
 }catch(err){if(request!==attachmentPreviewSequence)return;showFailure();note.textContent='No se puede abrir la vista previa: '+messageError(err)}
}
function viewerAttachmentLinks(t){
 const saved=t.attachments.map(a=>attachmentActions(t,a)).join(' ');
 const pending=pendingForActivity(t.id).map(a=>`<span class="pending-attachment-label" title="Se verificará automáticamente al recuperar la conexión">⏳ ${esc(a.file_name)} (pendiente)</span>`).join(' ');
 return (saved+' '+pending).trim()||'<span class="muted">Sin anexos adjuntos</span>';
}
function viewerCard(t){
 const state=status(t),stateClass=state==='Por empezar'?'status-pending':state==='Terminado'?'status-finished':'status-active';
 const collapsed=collapsedActivities.has(String(t.id));
 const stageOpen=sectionIsOpen(t.id,'stages')?' open':'';
 const progress=Math.max(0,Math.min(100,Number(t.progress)||0));
 const verification=Math.max(0,Math.min(100,Number(t.verification)||0));
 const phase=`<details class="viewer-section viewer-stages" data-activity-section="${t.id}" data-section-kind="stages"${stageOpen}><summary>7 etapas · consulta</summary><div class="viewer-section-inner"><div class="viewer-step"><b>1. Propuesta:</b><span>${esc(t.start||'Sin fecha')} – ${esc(t.end||'Sin fecha')}<small>Después de: ${esc(viewerLinkedActivity(t.before))}</small></span></div><div class="viewer-step"><b>2. Revisión:</b><span>${esc(t.reviewers||'Pendiente')}</span></div><div class="viewer-step"><b>3. Autorizado:</b><span>${esc(t.authorizer||'Pendiente')}</span></div><div class="viewer-step"><b>4. Avance de Obra:</b><span>${progress}%</span></div><div class="viewer-progress"><div style="width:${progress}%"></div></div><div class="viewer-step"><b>5. Verificación:</b><span>${verification}%</span></div><div class="viewer-progress"><div style="width:${verification}%"></div></div><div class="viewer-step"><b>6. Documentado (opcional):</b><span>${viewerAttachmentLinks(t)}</span></div><div class="viewer-step"><b>7. Completado:</b><span>${t.steps[6]?esc(t.completedDate||'Sí'):'No'}</span></div></div></details>`;
 return `<article class="task task-viewer ${stateClass} ${collapsed?'is-collapsed':''}" id="activity-${t.id}"><div class="head"><span class="number">${esc(t.annex)}</span><h3>${statusDot(t)}${esc(t.title)}</h3><button type="button" class="btn collapse-btn" data-collapse="${t.id}" aria-expanded="${!collapsed}" title="Minimizar o expandir actividad">${collapsed?'+':'−'}</button></div><div class="task-details"><div class="muted viewer-subheading">Anexo ${esc(t.annex)} · Semana de alta: ${esc(t.weekStart)} al ${esc(t.weekEnd)}</div>${phase}${commentsSection(t)}</div></article>`;
}
function isMobileTimeline(){return typeof window!=='undefined' && window.matchMedia('(max-width: 760px)').matches}
function timelineHTML(print=false,compact=false,mobile=isMobileTimeline()&&!print){
 const d=timelineData(),today=new Date(),todayDay=Math.floor(Date.UTC(today.getFullYear(),today.getMonth(),today.getDate())/86400000);
 const dayISO=n=>new Date(n*86400000).toISOString().slice(0,10);
 const dayNames=['Lun','Mar','Mié','Jue','Vie','Sáb','Dom'];
 const pos=n=>(100*(n-d.lo)/d.total).toFixed(5),width=n=>(100*n/d.total).toFixed(5);
 const todayVisible=todayDay>=d.lo&&todayDay<=d.hi;
 const weeks=d.weeks.map(w=>`<div class="tl-week-ref" style="width:${width(7)}%">Sem-${esc(w.label.split(' · ')[0].slice(1))}</div>`).join('');
 const days=Array.from({length:d.total},(_,i)=>{const n=d.lo+i,dt=new Date(n*86400000);return `<div class="tl-day-ref ${Math.floor(i/7)%2===0?'week-blue':'week-white'} ${n===todayDay?'is-today':''}" title="${dayISO(n)}">${dayNames[i%7]} ${String(dt.getUTCDate()).padStart(2,'0')}</div>`}).join('');
 const head=`<div class="tl-head-ref"><div class="tl-weeks-ref">${weeks}</div><div class="tl-days-ref">${days}</div>${todayVisible?`<span class="tl-today-tag" style="left:${pos(todayDay+.5)}%">HOY</span>`:''}</div>`;
 const rows=tasks.map(t=>{
  const words=t.title.trim().split(/\s+/),limit=mobile?4:6,title=words.slice(0,limit).join(' ')+(words.length>limit?'…':'');
  const start=d.valid(t.start)?d.day(t.start):null,end=d.valid(t.end)?d.day(t.end):null,real=d.valid(t.completedDate)?d.day(t.completedDate):null;
  const progress=Math.min(100,Math.max(0,Number(t.progress)||0));
  const projected=start!==null&&end!==null&&end>=start;
  const cardStart=projected?start:(real!==null?real:d.lo),cardEnd=projected?end:cardStart;
  const extended=real!==null&&projected&&real>end;
  const span=Math.max(1,cardEnd-cardStart+1),tiny=mobile&&span===1;
  const label=print?`<span class="tl-annex">${esc(t.annex)}</span><span class="tl-title-text">${esc(title)}</span>`:`<button class="tl-card-link" data-jump="${t.id}" title="Ir a la actividad: ${esc(t.title)}"><span class="tl-annex">${esc(t.annex)}</span><span class="tl-title-text">${esc(title)}</span></button>`;
  const card=`<div class="tl-project-card ${status(t)==='Por empezar'?'tl-pending':status(t)==='Terminado'?'tl-finished':'tl-active'} ${tiny?'tl-brief':''}" style="left:${pos(cardStart)}%;width:${width(span)}%" title="Proyectado: ${esc(t.start||'Sin fecha')} a ${esc(t.end||'Sin fecha')} · Avance: ${progress}%"><div class="tl-card-top"><div class="tl-card-title">${statusDot(t)}${label}</div>${mobile?`<span class="tl-percent-inline">${progress}%</span>`:''}</div>${mobile||compact?'':`<div class="tl-card-percent">Obra a: ${progress}%</div>`}${mobile?'':`<div class="tl-card-progress"><div style="width:${progress}%"></div></div>`}</div>`;
  const red=extended?`<div class="tl-delay" style="left:${pos(end+1)}%;width:${width(real-end)}%" title="Fin proyectado: ${t.end} · Fin real: ${t.completedDate}"><span>Finalizó en</span><span class="tl-delay-arrow">➜</span></div>`:'';
  const actual=real!==null?`<span class="tl-actual-marker" style="left:${pos(real+.5)}%" title="Fin real: ${t.completedDate}">◆</span>`:'';
  const cells=Array.from({length:d.total},(_,i)=>`<div class="tl-background-cell ${i%7===0?'week-start':''} ${Math.floor(i/7)%2===0?'week-blue':'week-white'} ${mobile&&d.lo+i===todayDay?'is-today':''}"></div>`).join('');
  return `<div class="tl-row-ref"><div class="tl-row-cells">${cells}</div>${card}${red}${actual}</div>`;
 }).join('');
 return `<div class="tl-reference-grid ${compact?'tl-compact':''} ${mobile?'tl-mobile-view':''}" style="--day-count:${d.total}">${head}${rows}${todayVisible?`<span class="tl-today-continuous" style="left:${pos(todayDay+.5)}%"></span>`:''}</div>`;
}

document.addEventListener('click',e=>{const b=e.target.closest('[data-jump]');if(!b)return;$('search').value='';render();const target=$('activity-'+b.dataset.jump);if(target){collapsedActivities.delete(String(b.dataset.jump));persistCollapsed();target.classList.remove('is-collapsed');target.querySelector('.collapse-btn')?.setAttribute('aria-expanded','true');target.querySelector('.collapse-btn').textContent='−';target.scrollIntoView({behavior:'smooth',block:'center'});history.replaceState(null,'','#activity-'+b.dataset.jump)}});

const COLLAPSE_KEY='dydem-online-collapsed-activities-v1';
let collapsePreferencesInitialized=false;
const savedCollapsed=storeGet(COLLAPSE_KEY);
let collapsedIds;
try{collapsedIds=savedCollapsed===null?tasks.map(t=>String(t.id)):JSON.parse(savedCollapsed).map(String)}
catch(e){collapsedIds=tasks.map(t=>String(t.id))}
const collapsedActivities=new Set(collapsedIds);
// Guardar preferencias después de la primera carga compartida, no antes.
function persistCollapsed(){storeSet(COLLAPSE_KEY,JSON.stringify([...collapsedActivities]))}

let compactTimeline=isMobileTimeline();
let timelineViewportMobile=isMobileTimeline();
function setTimelineButtonLabel(){
 const button=$('timeline-mode');
 if(button)button.textContent=compactTimeline?'Vista completa':'Vista compacta';
}
document.addEventListener('click',e=>{
 if(e.target.id!=='timeline-mode')return;
 compactTimeline=!compactTimeline;
 setTimelineButtonLabel();
 const host=$('timeline');
 if(host)host.innerHTML=timelineHTML(false,compactTimeline,isMobileTimeline());
});
window.addEventListener('resize',()=>{
 const mobile=isMobileTimeline();
 if(mobile===timelineViewportMobile)return;
 timelineViewportMobile=mobile;
 compactTimeline=mobile;
 setTimelineButtonLabel();
 const host=$('timeline');
 if(host)host.innerHTML=timelineHTML(false,compactTimeline,mobile);
});
function render(){const w=weekInfo();document.querySelector('header small').textContent=`CONTROL DE OBRA · SEMANA ${w.week} / ${w.year}`;document.querySelector('header p').textContent=`Semana actual: ${w.start} al ${w.end} · Seguimiento por 7 etapas`;let q=$('search').value.toLowerCase();const counts={'Por empezar':0,'En proceso':0,'Terminado':0};tasks.forEach(t=>counts[status(t)]++);$('total').textContent=tasks.length;$('nstart').textContent=counts['Por empezar'];$('nprogress').textContent=counts['En proceso'];$('ndone').textContent=counts['Terminado'];$('board').innerHTML=['Por empezar','En proceso','Terminado'].map(st=>{const list=tasks.filter(t=>status(t)===st&&(`${t.id} ${t.title}`).toLowerCase().includes(q));return `<section class="column"><h2>${st} (${counts[st]})</h2>${list.length?list.map(card).join(''):'<div class="empty">Sin actividades</div>'}</section>`}).join('');setTimelineButtonLabel();$('timeline').innerHTML=timelineHTML(false,compactTimeline,isMobileTimeline());}
function hybridReadOnlyStage(t,i){
 const pct=value=>Math.max(0,Math.min(100,Number(value)||0));
 let content='';
 let progress='';
 if(i===0){
  content=`${esc(t.start||'Sin fecha')} – ${esc(t.end||'Sin fecha')}
   <small>Debe completarse antes: ${esc(viewerLinkedActivity(t.before))}</small>
   <small>Solo después de: ${esc(viewerLinkedActivity(t.after))}</small>`;
 }else if(i===1){
  content=`${esc(t.reviewers||'Pendiente')}${t.reviewAnnex?`<small>Referencia de revisión: ${esc(t.reviewAnnex)}</small>`:''}`;
 }else if(i===2){
  content=esc(t.authorizer||'Pendiente');
 }else if(i===3||i===4){
  const value=pct(i===3?t.progress:t.verification);
  content=`<strong>${value}%</strong>`;
  progress=`<div class="viewer-progress hybrid-progress"><div style="width:${value}%"></div></div>`;
 }else if(i===5){
  content=`${viewerAttachmentLinks(t)}<small>Documentado: ${t.steps[5]?'Sí':'No'}</small>`;
 }else if(i===6){
  content=t.steps[6]?esc(t.completedDate||'Sí'):'No';
 }
 return `<div class="hybrid-readonly-step" data-step-readonly="${i}">
  <b class="hybrid-read-label">${i+1}. ${esc(names[i])}${i===5?' (opcional)':''}:</b>
  <div class="hybrid-read-value">${content}</div>
  ${progress}
 </div>`;
}
function card(t){if(!isAdmin()&&!isCustom())return viewerCard(t);const steps=names.map((n,i)=>{if(isCustom()&&!canEditStep(i))return hybridReadOnlyStage(t,i);const canEdit=canEditStep(i);let detail='';if(i===0)detail=`<div class="row" style="margin-top:8px"><div class="field"><label>Inicio tentativo</label><input type="date" data-id="${t.id}" data-field="start" ${canEdit?'':'disabled'} value="${esc(t.start)}"></div><div class="field"><label>Final tentativo</label><input type="date" data-id="${t.id}" data-field="end" ${canEdit?'':'disabled'} value="${esc(t.end)}"></div></div><div class="row" style="margin-top:8px"><div class="field"><label>Debe completarse antes</label><select data-id="${t.id}" data-field="before" ${canEdit?'':'disabled'}>${selectOptions(t.id,t.before)}</select></div><div class="field"><label>Solo después de esta actividad</label><select data-id="${t.id}" data-field="after" ${canEdit?'':'disabled'}>${selectOptions(t.id,t.after)}</select></div></div>`;
if(i===1)detail=`<div class="detail">Revisores: ${esc(t.reviewers||'Pendiente')}\nAnexo de diagramas/especificaciones/materiales: ${esc(t.reviewAnnex||'Sin código')}</div>`;
if(i===2)detail=`<div class="detail">Autorizó: ${esc(t.authorizer||'Pendiente')}</div>`;
if(i===3||i===4){let v=i===3?t.progress:t.verification;detail=`<div class="row" style="margin-top:6px"><span class="muted">${i===3?'Avance de obra':'Verificación'}</span><input class="pct" type="number" min="0" max="100" data-id="${t.id}" data-field="${i===3?'progress':'verification'}" ${canEdit?'':'disabled'} value="${v}">%</div><div class="progress"><div style="width:${v}%"></div></div>`}
if(i===5)detail=`<div class="detail">${viewerAttachmentLinks(t)}</div>`;
if(i===6)detail=`<div class="row" style="margin-top:6px"><div class="field"><label>Fecha de compleción</label><input type="date" data-id="${t.id}" data-field="completedDate" ${canEdit?'':'disabled'} value="${esc(t.completedDate)}"></div></div>`;
return `<div class="step"><label><input type="checkbox" data-step="${i}" data-id="${t.id}" ${canEdit?'':'disabled'} ${t.steps[i]?'checked':''}>${i+1}. ${n}${i===5?' (opcional)':''}</label><details><summary>Ver / editar datos</summary>${detail}${[1,2,5].includes(i)&&canEdit?`<button class="btn secondary" style="margin:7px 0 0 24px" data-edit="${i}" data-id="${t.id}">${i===5?'Gestionar anexos':'Editar datos'}</button>`:''}</details></div>`}).join('');return `<article class="task ${isCustom()?'task-hybrid':''} ${status(t)==='Por empezar'?'status-pending':status(t)==='Terminado'?'status-finished':'status-active'} ${collapsedActivities.has(String(t.id))?'is-collapsed':''}" id="activity-${t.id}"><div class="head"><span class="number">${esc(t.annex)}</span><h3>${statusDot(t)}${esc(t.title)}</h3><button type="button" class="btn collapse-btn" data-collapse="${t.id}" aria-expanded="${!collapsedActivities.has(String(t.id))}" title="Minimizar o expandir actividad">${collapsedActivities.has(String(t.id))?'+':'−'}</button></div><div class="task-details"><div class="muted" style="margin-top:7px">Anexo ${esc(t.annex)} · Semana de alta: ${esc(t.weekStart)} al ${esc(t.weekEnd)}</div>${isCustom()?`<details class="viewer-section viewer-stages hybrid-stages" data-activity-section="${t.id}" data-section-kind="stages" ${sectionIsOpen(t.id,'stages')?'open':''}><summary>7 etapas · ${t.steps.filter(Boolean).length}/7 completadas</summary><div class="viewer-section-inner hybrid-steps">${steps}</div></details>`:`<div class="section-title">7 ETAPAS · ${t.steps.filter(Boolean).length}/7 completadas</div><div class="steps">${steps}</div>`}${canEditStep(0)?`<button class="btn secondary" style="margin-top:10px" data-rename="${t.id}">Editar descripción</button>`:''} ${canDeleteActivity()?`<button type="button" class="btn secondary" style="margin-top:10px;border-color:#c93434;color:#a52121" data-delete="${t.id}">Eliminar actividad</button>`:''}${commentsSection(t)}</div></article>`}
let active=null;function modal(title,help,fields,action){if(!isAdmin()&&!(action?.type==='edit'&&canEditStep(action.step))&&!(action?.type==='files'&&canEditStep(5)))return;active=action;$('modal-title').textContent=title;$('modal-help').textContent=help;$('modal-fields').innerHTML=fields;$('modal-error').textContent='';$('modal').hidden=false;}
function close(){if(attachmentUploadBusy){alert('La carga de archivos sigue en curso. Espera a que termine.');return}active=null;$('modal').hidden=true;render()}
$('modal-cancel').onclick=close;
function requiredDates(t){return !!t.start&&!!t.end&&t.end>=t.start}
function missing(){return tasks.filter(t=>!requiredDates(t)||t.steps[1]&&!t.reviewers.trim()||t.steps[2]&&!t.authorizer.trim()||t.steps[6]&&!t.completedDate)}
function startup(){const incomplete=missing();if(!incomplete.length)return;const fields=incomplete.map(t=>`<fieldset style="border:1px solid #dce3ed;border-radius:8px"><legend>#${t.id} — ${esc(t.title.slice(0,75))}</legend><div class="row">${!requiredDates(t)?`<div class="field"><label>Inicio tentativo *</label><input type="date" name="start-${t.id}" value="${esc(t.start)}" required></div><div class="field"><label>Final tentativo *</label><input type="date" name="end-${t.id}" value="${esc(t.end)}" required></div>`:''}${t.steps[1]&&!t.reviewers.trim()?`<div class="field"><label>Personas que revisaron *</label><input name="reviewers-${t.id}" required></div>`:''}${t.steps[2]&&!t.authorizer.trim()?`<div class="field"><label>Persona que autorizó *</label><input name="authorizer-${t.id}" required></div>`:''}${t.steps[6]&&!t.completedDate?`<div class="field"><label>Fecha de compleción *</label><input type="date" name="completedDate-${t.id}" required></div>`:''}</div></fieldset>`).join('');modal('Completar datos obligatorios',`Hay ${incomplete.length} actividad(es) con datos obligatorios pendientes. Puedes cerrar y completarlos después; no se marcarán las etapas correspondientes hasta cumplir sus requisitos.`,fields,{type:'startup',ids:incomplete.map(t=>t.id)})}
function editStep(t,i){if(!canEditStep(i))return;if(i===1)modal(`Revisión · Actividad ${t.id}`,'Indica las personas que realizaron la revisión. El código de anexo es opcional.',`<div class="field"><label>Nombre(s) de revisores *</label><textarea name="reviewers" required>${esc(t.reviewers)}</textarea></div><div class="field"><label>Código de anexo (opcional)</label><input name="reviewAnnex" value="${esc(t.reviewAnnex)}"></div>`,{type:'edit',id:t.id,step:i});if(i===2)modal(`Autorización · Actividad ${t.id}`,'Indica quién autorizó la actividad.',`<div class="field"><label>Nombre de quien autorizó *</label><input name="authorizer" value="${esc(t.authorizer)}" required></div>`,{type:'edit',id:t.id,step:i});if(i===5)modal(`Documentación · Actividad ${t.id}`,'Agrega imágenes, videos, documentos y otros anexos. Se almacenan en la nube y se comparten con el equipo.',`<div class="field"><label>Agregar archivos</label><input type="file" id="attachments-input" multiple><p class="attachment-upload-help">Máximo de DYDEM: 500 MB por archivo. El almacenamiento actual de Supabase admite hasta 50 MB por archivo. DYDEM registra cada carga antes de enviarla y verifica su aparición en la actividad al finalizar. No cierres la ventana hasta recibir la confirmación.</p><span id="attachment-upload-status" role="status"></span></div><div id="attachment-list">${attachmentList(t)}</div>`,{type:'files',id:t.id,step:i})}
function attachmentList(t){
 const files=t.attachments.map(a=>`<div class="attachment">${attachmentActions(t,a)}<button type="button" class="btn danger" data-remove-file="${esc(a.id)}" data-id="${t.id}">Quitar</button></div>`).join('');
 const pending=pendingForActivity(t.id).map(a=>`<div class="attachment pending-attachment"><span class="pending-attachment-info">⏳ <b>${esc(a.file_name)}</b><small> Pendiente: ${a.last_error?'No se pudo confirmar.':'Se recuperará automáticamente cuando esté completo.'} ${esc(a.last_error||'')}</small></span><button type="button" class="btn secondary" data-recover-upload="${esc(a.id)}" data-id="${t.id}">Comprobar</button></div>`).join('');
 return (files+pending)||'<span class="muted">No hay archivos adjuntos.</span>';
}
function canCheck(t,i){if(i>0&&!t.steps[i-1]&&!(i===6&&t.steps[4]))return 'Completa primero la etapa anterior.';if(i===0&&!requiredDates(t))return 'Completa las fechas tentativas de inicio y final.';if(i===1&&!t.reviewers.trim())return 'Introduce al menos un nombre de revisor.';if(i===2&&!t.authorizer.trim())return 'Introduce el nombre de quien autorizó.';if(i===3&&t.progress!==100)return 'El avance de obra debe llegar al 100 %.';if(i===4&&t.verification!==100)return 'La verificación debe llegar al 100 %.';if(i===6&&!t.completedDate)return 'Indica la fecha de compleción.';if(i===6&&t.before&&task(t.before)&&!task(t.before).steps[6])return 'La actividad anterior enlazada debe estar completada.';return ''}
function autoCheck(t,i){if(!canCheck(t,i))t.steps[i]=true}
function uncheck(t,i){if(isCustom()){t.steps[i]=false;return}if(i===5){t.steps[5]=false;return}for(let j=i;j<7;j++)t.steps[j]=false}
function linkError(t,field,value){if(!value)return '';if(String(value)===String(t.id))return 'No se puede enlazar una actividad consigo misma.';if(field==='before'&&String(t.after)===String(value)||field==='after'&&String(t.before)===String(value))return 'Las dos dependencias no pueden apuntar a la misma actividad.';let next=task(value),seen=new Set([t.id]);while(next){if(seen.has(next.id))return 'Esta relación crearía un ciclo de dependencias.';seen.add(next.id);next=task(field==='before'?next.before:next.after)}return ''}
// Storage privado de Supabase. metadata.path pertenece al bucket; nunca al navegador.
async function putFile(t,file,intent){
 if(!canEditStep(5))throw Error('Sin permisos para adjuntar archivos');
 if(file.size>MAX_ATTACHMENT_BYTES)throw Error('No se permite subir archivos de más de 500 MB.');
 if(file.size>CURRENT_STORAGE_LIMIT_BYTES)throw Error('El archivo supera los 50 MB permitidos actualmente por el almacenamiento de Supabase. El máximo de la aplicación es 500 MB, pero el proyecto requiere ampliar su límite de Storage.');
 if(!intent?.id||!intent?.path)throw Error('Falta el registro previo de la carga');
 const {id,path}=intent;
 const name=file.name;
 const report=msg=>{const el=$('attachment-upload-status');if(el)el.textContent=msg};
 report('Subiendo '+file.name+'…');
 if(file.size<=6*1024*1024){
  const {error}=await cloud.storage.from('activity-attachments').upload(path,file,{upsert:false,contentType:file.type||'application/octet-stream'});
  if(error)throw error;
 }else{
  // El protocolo TUS evita retransmitir el archivo completo al fallar una conexión móvil.
  const tus=await loadAttachmentLibrary('tus','https://cdn.jsdelivr.net/npm/tus-js-client@3.1.3/dist/tus.min.js');
  const {data:{session}}=await cloud.auth.getSession();
  if(!session?.access_token)throw Error('La sesión expiró. Vuelve a iniciar sesión.');
  const host=new URL(connectionConfig().url).hostname;
  const ref=host.split('.')[0];
  if(!/^[a-z0-9-]+$/.test(ref))throw Error('Proyecto de Storage no válido');
  await new Promise((resolve,reject)=>{
   const up=new tus.Upload(file,{
    endpoint:`https://${ref}.storage.supabase.co/storage/v1/upload/resumable`,
    headers:{authorization:'Bearer '+session.access_token,'x-upsert':'false'},
    retryDelays:[0,3000,5000,10000,20000],
    uploadDataDuringCreation:true,removeFingerprintOnSuccess:true,
    // A resume fingerprint must include the exact Storage destination, not only
    // the local filename: two activities can upload files with identical names.
    fingerprint:(source,opts)=>Promise.resolve(
      ['dydem-v2',opts.metadata.objectName,source.name,source.size,source.lastModified||0].join('|')),
    metadata:{bucketName:'activity-attachments',objectName:path,contentType:file.type||'application/octet-stream',cacheControl:'3600'},
    chunkSize:6*1024*1024,
    onError:reject,
    onProgress:(sent,total)=>report('Subiendo '+file.name+': '+Math.round(sent/Math.max(total,1)*100)+'%'),
    onSuccess:resolve
   });
   up.findPreviousUploads().then(prev=>{
    if(prev.length)up.resumeFromPreviousUpload(prev[0]);
    up.start()
   }).catch(reject);
  });
 }
 report('Archivo subido: '+file.name);
 return {id,name:file.name,size:file.size,type:file.type,path};
}

const pendingFileRegistrations=new Map();
let pendingAttachmentIntents=new Map();
let attachmentRecoveryRunning=false;
function pendingForActivity(id){return pendingAttachmentIntents.get(Number(id))||[]}
function addPendingIntent(intent){
 const id=Number(intent.activity_id);
 const list=pendingForActivity(id).filter(x=>x.id!==intent.id);
 list.push(intent);pendingAttachmentIntents.set(id,list);
}
function forgetPendingIntent(intentId,activityId){
 const id=Number(activityId);
 const left=pendingForActivity(id).filter(x=>x.id!==intentId);
 if(left.length)pendingAttachmentIntents.set(id,left);else pendingAttachmentIntents.delete(id);
}
async function reconcileAttachmentIntents(){
 if(!isSignedIn()||attachmentRecoveryRunning)return;
 attachmentRecoveryRunning=true;
 try{
  const {data,error}=await cloud.from('activity_upload_intents')
    .select('id,activity_id,file_name,file_size,mime_type,storage_path,created_at')
    .eq('uploaded_by',currentAccount.id).eq('status','pending')
    .order('created_at',{ascending:true});
  if(error)throw error;
  const outstanding=new Map(),repaired=[];
  for(const intent of data||[]){
   let completed=null;
   try{
    const result=await cloud.rpc('complete_activity_upload',{p_upload_id:intent.id});
    if(result.error)throw result.error;
    completed=result.data;
   }catch(err){
    // Do not lose the intent if Storage or the data API is temporarily unreachable.
    intent.last_error=messageError(err);
   }
   if(completed?.status==='linked'){repaired.push(intent.id);continue}
   const id=Number(intent.activity_id),items=outstanding.get(id)||[];
   items.push(intent);outstanding.set(id,items);
  }
  // Preserve an intent created during a concurrent upload; discard outdated intents otherwise.
  if(attachmentUploadBusy)for(const [id,items] of pendingAttachmentIntents){
   for(const item of items){
    if(repaired.includes(item.id))continue;
    if(!outstanding.has(id))outstanding.set(id,[]);
    if(!outstanding.get(id).some(x=>x.id===item.id))outstanding.get(id).push(item);
   }
  }
  pendingAttachmentIntents=outstanding;
  if(repaired.length)syncState('Se recuperaron '+repaired.length+' anexo(s) pendientes');
 }finally{attachmentRecoveryRunning=false}
}

function pendingUploadKey(t,file){return [t.id,file.name,file.size,file.lastModified].join('::')}
function applyAttachmentServerData(activityId,data,revision){
 const id=Number(activityId),next=migrate({...data,id});
 const index=tasks.findIndex(a=>Number(a.id)===id);
 if(index>=0)tasks[index]=next;
 revisions.set(id,Number(revision));
 lastSynced.set(id,JSON.stringify(next));
 const list=$('attachment-list');
 if(list&&active?.type==='files'&&Number(active.id)===id)list.innerHTML=attachmentList(next);
 return next;
}
async function prepareAttachmentUpload(t,file){
 const available=pendingForActivity(t.id).find(a=>a.file_name===file.name&&Number(a.file_size)===file.size);
 if(available)return {id:available.id,path:available.storage_path,activity_id:t.id,
  name:available.file_name,size:Number(available.file_size),type:available.mime_type};
 const uploadId=crypto.randomUUID();
 const safeName=file.name.replace(/[^a-zA-Z0-9._-]+/g,'_').slice(-100)||'anexo';
 const {data,error}=await cloud.rpc('begin_activity_upload',{
  p_activity_id:Number(t.id),p_upload_id:uploadId,p_file_name:file.name,
  p_storage_name:safeName,p_file_size:file.size,p_mime_type:file.type||'application/octet-stream'
 });
 if(error)throw error;
 if(!data?.id||!data.path)throw Error('No se pudo crear el registro previo del archivo');
 addPendingIntent({id:data.id,activity_id:Number(t.id),file_name:data.name,
  file_size:data.size,mime_type:data.type,storage_path:data.path,created_at:new Date().toISOString()});
 const list=$('attachment-list');if(list)list.innerHTML=attachmentList(task(t.id)||t);
 return data;
}
async function confirmUploadedAttachment(t,intent){
 const id=Number(t.id);
 const {data,error}=await cloud.rpc('complete_activity_upload',{p_upload_id:intent.id});
 if(error)throw error;
 if(data?.status!=='linked'||!data.data||!Number.isInteger(Number(data.revision)))
  throw Error('El archivo aún está pendiente de confirmación en Supabase');
 forgetPendingIntent(intent.id,id);
 pendingFileRegistrations.delete(intent.id);
 const next=applyAttachmentServerData(id,data.data,data.revision);
 syncState('Anexo guardado y verificado');
 return next;
}
async function getFile(meta){if(!isSignedIn())throw Error('Acceso requerido');if(!meta?.path)throw Error('Este anexo procede de una versión local. Debes volver a cargar el archivo original en DYDEM en línea.');if(!meta.path.startsWith(PROJECT_ID+'/'))throw Error('Referencia de archivo inválida');const {data,error}=await cloud.storage.from('activity-attachments').download(meta.path);if(error)throw error;return data}
async function deleteFile(meta){if(!canEditStep(5))throw Error('Sin permisos');if(!meta?.path)return;const {error}=await cloud.storage.from('activity-attachments').remove([meta.path]);if(error)throw error}
$('board').addEventListener('click',async e=>{
 const b=e.target.closest('button');if(!b)return;
 const t=task(b.dataset.id||b.dataset.delete||b.dataset.rename||b.dataset.collapse);
 if(!t)return;
 if(b.dataset.collapse){const id=String(t.id);if(collapsedActivities.has(id))collapsedActivities.delete(id);else collapsedActivities.add(id);persistCollapsed();render();return}
 if(b.dataset.delete){if(!canDeleteActivity())return;if(!confirm(`¿Eliminar actividad ${t.id}?`))return;syncState('Eliminando…',false,true);const {error}=await cloud.rpc('delete_activity',{p_id:t.id,p_expected_revision:revisions.get(Number(t.id))});if(error){alert('No se pudo eliminar: '+messageError(error));await reloadActivities(true);return}collapsedActivities.delete(String(t.id));persistCollapsed();await reloadActivities(true);return}
 if(b.dataset.rename){if(!canEditStep(0))return;let title=prompt('Descripción de la actividad:',t.title);if(title?.trim()){t.title=title.trim();save();render()}return}
 if(b.dataset.edit!==undefined){const i=Number(b.dataset.edit);if(canEditStep(i))editStep(t,i)}
});
document.addEventListener('toggle',event=>{
 const d=event.target;
 if(!(d instanceof HTMLDetailsElement)||!d.matches('[data-activity-section]')||!d.isConnected)return;
 sectionOpen.set(d.dataset.sectionKind+':'+d.dataset.activitySection,d.open);
},true);
$('board').addEventListener('input',event=>{
 const el=event.target;
 if(el.matches('textarea[data-comment-input]'))commentDrafts.set(Number(el.dataset.commentInput),el.value);
});
$('board').addEventListener('click',async event=>{
 const button=event.target.closest('button[data-delete-comment]');
 if(!button)return;
 if(!isAdmin()){
  alert('Solo los administradores pueden eliminar comentarios.');
  return;
 }
 const activityId=Number(button.dataset.commentActivity),commentId=Number(button.dataset.deleteComment);
 const activity=task(activityId);
 if(!activity || !commentsFor(activityId).some(c=>Number(c.id)===commentId))return;
 if(!confirm('¿Eliminar definitivamente este comentario? Esta acción no se puede deshacer.'))return;
 const section=button.closest('.comments-section');
 const feedback=section?.querySelector('.comment-feedback');
 button.disabled=true;
 if(feedback)feedback.textContent='Eliminando comentario…';
 try{
  const {data,error}=await cloud.from('activity_comments').delete()
    .eq('id',commentId).eq('activity_id',activityId).eq('project_id',PROJECT_ID)
    .select('id');
  if(error)throw error;
  if(!data||data.length!==1)throw Error('No se confirmó la eliminación. Comprueba tus permisos y actualiza la página.');
  await reloadComments();
  if(section?.isConnected){
   const feed=section.querySelector('[data-comment-feed]');
   if(feed)feed.innerHTML=commentListHTML(activity);
   const count=section.querySelector('.comment-count');
   if(count)count.textContent=String(commentsFor(activityId).length);
   if(feedback)feedback.textContent='Comentario eliminado.';
  }
 }catch(error){
  if(feedback)feedback.textContent='No se pudo eliminar: '+messageError(error);
  button.disabled=false;
 }
});
$('board').addEventListener('submit',async event=>{
 const form=event.target.closest('form[data-comment-form]');
 if(!form)return;
 event.preventDefault();
 if(!canPostComment())return;
 const activityId=Number(form.dataset.commentForm),activity=task(activityId);
 if(!activity)return;
 const input=form.querySelector('textarea[data-comment-input]'),button=form.querySelector('button[type="submit"]'),feedback=form.querySelector('.comment-feedback');
 const body=input.value.trim();
 if(!body||body.length>2000){feedback.textContent='Escribe entre 1 y 2000 caracteres.';return}
 button.disabled=true;feedback.textContent='Publicando comentario…';
 try{
  const {error}=await cloud.from('activity_comments').insert({project_id:PROJECT_ID,activity_id:activityId,body});
  if(error)throw error;
  input.value='';commentDrafts.delete(activityId);
  await reloadComments();
  const feed=form.closest('.comments-section').querySelector('[data-comment-feed]');
  if(feed)feed.innerHTML=commentListHTML(activity);
  const count=form.closest('.comments-section').querySelector('.comment-count');
  if(count)count.textContent=String(commentsFor(activityId).length);
  feedback.textContent='Comentario publicado.';
 }catch(error){feedback.textContent='No se pudo publicar: '+messageError(error)}
 finally{button.disabled=false}
});
$('board').addEventListener('change',e=>{
 const el=e.target,t=task(el.dataset.id);
 if(!t||!isSignedIn())return;
 if(el.dataset.step!==undefined){
  const i=Number(el.dataset.step);
  if(!canEditStep(i))return;
  if(!el.checked){uncheck(t,i)}
  else{const error=canCheck(t,i);if(error){alert(error);if([1,2,5].includes(i))editStep(t,i);else if(i===0&&isAdmin())startup()}else t.steps[i]=true}
 }else if(el.dataset.field){
  const f=el.dataset.field,i=stageForField(f);if(!canEditStep(i))return;
  let v=el.value;
  if(f==='progress'||f==='verification'){
   v=Math.max(0,Math.min(100,Number(v)||0));t[f]=v;
   if(v<100)uncheck(t,i);else autoCheck(t,i);
  }else if(f==='before'||f==='after'){
   const error=linkError(t,f,v);if(error){alert(error);render();return}t[f]=v;
  }else{
   t[f]=v;
   if(f==='start'||f==='end'){if(!requiredDates(t))uncheck(t,0);else autoCheck(t,0)}
   if(f==='completedDate'){if(!v)uncheck(t,6);else autoCheck(t,6)}
  }
 }else return;
 save();render();
});
$('modal-form').onsubmit=async e=>{e.preventDefault();if(!active||attachmentUploadBusy||!(isAdmin()||active.type==='edit'&&canEditStep(active.step)||active.type==='files'&&canEditStep(5)))return;const submitButton=e.target.querySelector('button[type="submit"]');if(submitButton)submitButton.disabled=true;attachmentUploadBusy=active.type==='files';let form=new FormData(e.target);let err='';try{if(active.type==='startup'){for(let id of active.ids){let t=task(id);for(let f of ['start','end','reviewers','authorizer','completedDate']){let k=f+'-'+id;if(form.has(k))t[f]=String(form.get(k)).trim()}if(requiredDates(t))autoCheck(t,0);if(!requiredDates(t))err=`Las fechas de la actividad ${id} deben estar completas y la final no puede ser anterior a la inicial.`}}else if(active.type==='edit'){let t=task(active.id);if(active.step===1){t.reviewers=String(form.get('reviewers')||'').trim();t.reviewAnnex=String(form.get('reviewAnnex')||'').trim();if(t.reviewers)autoCheck(t,1);if(!t.reviewers)err='Se requiere al menos un nombre de revisor.'}if(active.step===2){t.authorizer=String(form.get('authorizer')||'').trim();if(t.authorizer)autoCheck(t,2);if(!t.authorizer)err='El nombre de quien autorizó es obligatorio.'}}else if(active.type==='files'){
 let t=task(active.id);
 const files=Array.from($('attachments-input').files);
 for(const file of files){
  if(file.size>MAX_ATTACHMENT_BYTES)throw Error('No puedes subir archivos de más de 500 MB: '+file.name);
  if(file.size>CURRENT_STORAGE_LIMIT_BYTES)throw Error('El almacenamiento actual de Supabase admite como máximo 50 MB por archivo: '+file.name);
 }
 // Registrar anexos por separado, sin sobrescribir otras ediciones simultáneas.
 if(isDirty()){
  await save();
  if(isDirty())throw Error('Hay cambios de actividades pendientes. Guárdalos antes de cargar anexos.');
 }
 for(const file of files){
  const current=task(active.id)||t;
  const state=$('attachment-upload-status');
  // 1. Create a durable intent BEFORE uploading any bytes.
  const intent=await prepareAttachmentUpload(current,file);
  if(state)state.textContent='Verificando carga anterior: '+file.name;
  // A verification failure must NOT cause re-upload of an already-stored file.
  const prior=await cloud.rpc('complete_activity_upload',{p_upload_id:intent.id});
  if(prior.error)throw Error('No se pudo consultar la carga anterior. El archivo está registrado como pendiente: '+messageError(prior.error));
  const complete=prior.data;
  if(!complete||!['linked','pending'].includes(complete.status))throw Error('Estado de carga desconocido. No se enviará el archivo otra vez.');
  if(complete.status!=='linked'){
   // 2. Upload once. The durable intent survives a refresh or connection failure.
   if(state)state.textContent='Cargando '+file.name+'…';
   await putFile(current,file,intent);
  }
  // 3. Register and verify the reference BEFORE telling the user it is saved.
  if(state)state.textContent='Guardando y verificando referencia: '+file.name;
  try{
   await confirmUploadedAttachment(task(active.id)||current,intent);
  }catch(error){
   throw Error('La carga quedó pendiente en Supabase y NO se perderá. Abre nuevamente Documentado para recuperarla o pulsa «Comprobar». '+messageError(error));
  }
  if(state)state.textContent='Archivo registrado y verificado: '+file.name;
 }
}if(err){$('modal-error').textContent=err;return}await save();if(isDirty()){$('modal-error').textContent='Hay cambios pendientes; pulsa Guardar para reintentar antes de cerrar.';return}attachmentUploadBusy=false;close()}catch(ex){$('modal-error').textContent='No se pudo guardar: '+ex.message}finally{attachmentUploadBusy=false;if(submitButton)submitButton.disabled=false}};
$('modal-fields').addEventListener('click',async e=>{
 const recovery=e.target.closest('button[data-recover-upload]');
 if(recovery){
  if(!canEditStep(5))return;
  recovery.disabled=true;
  try{
   const {data,error}=await cloud.rpc('complete_activity_upload',{p_upload_id:recovery.dataset.recoverUpload});
   if(error)throw error;
   if(data?.status==='linked'){
    forgetPendingIntent(recovery.dataset.recoverUpload,recovery.dataset.id);
    applyAttachmentServerData(recovery.dataset.id,data.data,data.revision);
    $('modal-error').textContent='Anexo recuperado correctamente.';
   }else $('modal-error').textContent='El archivo todavía no está completo en Storage. Selecciónalo nuevamente para continuar la carga.';
   const current=task(recovery.dataset.id);
   if(current)$('attachment-list').innerHTML=attachmentList(current);
  }catch(err){$('modal-error').textContent='No se pudo recuperar: '+messageError(err)}
  finally{recovery.disabled=false}
  return;
 }
 const button=e.target.closest('button[data-remove-file]');
 if(!button||!canEditStep(5)||attachmentUploadBusy)return;
 const t=task(button.dataset.id),fileId=button.dataset.removeFile;
 if(!t||!confirm('¿Quitar este anexo de la actividad?'))return;
 button.disabled=true;
 try{
  const {data,error}=await cloud.rpc('remove_activity_file',{p_activity_id:Number(t.id),p_file_id:fileId});
  if(error)throw error;
  if(!data?.data)throw Error('No se confirmó la eliminación');
  applyAttachmentServerData(t.id,data.data,data.revision);
  if(data.removed_file?.path){
   try{await deleteFile(data.removed_file)}
   catch(error){alert('Se quitó la referencia, pero el archivo aún debe eliminarse de Storage: '+messageError(error))}
  }
  $('modal-error').textContent='Anexo eliminado correctamente.';
 }catch(err){$('modal-error').textContent='No se pudo quitar el anexo: '+messageError(err)}
 finally{button.disabled=false}
});
document.addEventListener('click',async e=>{
 const open=e.target.closest('[data-preview]');
 if(open){
  e.preventDefault();const t=task(open.dataset.id),meta=t?.attachments.find(x=>x.id===open.dataset.preview);
  if(meta)await previewAttachment(t,meta);
  return;
 }
 const a=e.target.closest('[data-download]');
 if(!a)return;
 e.preventDefault();
 const t=task(a.dataset.id),meta=t?.attachments.find(x=>x.id===a.dataset.download);
 if(!meta)return;
 try{
  const signed=await signedAttachmentUrl(meta),url=new URL(signed);
  url.searchParams.set('download',meta.name||'archivo');
  const link=document.createElement('a');link.href=url.toString();link.download=meta.name||'archivo';
  document.body.appendChild(link);link.click();link.remove();
 }catch(err){alert('No se pudo descargar: '+messageError(err))}
});
$('attachment-preview-close').onclick=closeAttachmentPreview;
$('attachment-preview-close-bottom').onclick=closeAttachmentPreview;
$('attachment-preview').addEventListener('click',e=>{if(e.target===$('attachment-preview'))closeAttachmentPreview()});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('attachment-preview').hidden)closeAttachmentPreview()});
$('modal-fields').addEventListener('change',e=>{if(e.target.id!=='attachments-input')return;const files=[...e.target.files];const status=$('attachment-upload-status');if(!status)return;if(files.some(f=>f.size>MAX_ATTACHMENT_BYTES))status.textContent='No está permitido subir archivos de más de 500 MB.';else if(files.some(f=>f.size>CURRENT_STORAGE_LIMIT_BYTES))status.textContent='Advertencia: alguno supera los 50 MB que permite el almacenamiento actual de Supabase.';else status.textContent=files.length?files.length+' archivo(s) listos para subir al guardar.':''});

$('add').onclick=async()=>{if(!canAddActivity())return;let title=prompt('Descripción de la nueva actividad:');if(!title?.trim())return;syncState('Creando actividad…',false,true);const {data,error}=await cloud.rpc('create_activity',{p_title:title.trim()});if(error){syncState('Error al crear',true);alert(messageError(error));return}const id=Number(data.id);collapsedActivities.add(String(id));persistCollapsed();await reloadActivities(true);if(isAdmin())startup()};
$('search').oninput=render;
$('save').onclick=async()=>{if(!canEditAnyStep())return;await save();if(!isDirty())alert('Información guardada en DYDEM en línea.')};
$('backup').onclick=()=>{if(!isAdmin())return;let blob=new Blob([JSON.stringify({project:'DYDEM',version:3,exportedAt:new Date().toISOString(),tasks},null,2)],{type:'application/json'});let a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='respaldo_dydem_'+new Date().toISOString().slice(0,10)+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),5000)};
$('import').onclick=()=>{if(isAdmin())$('importfile').click()};
$('importfile').onchange=async e=>{if(!isAdmin())return;try{let data=JSON.parse(await e.target.files[0].text());if(!Array.isArray(data.tasks))throw Error('Archivo inválido');if(!confirm('La importación inicial solo se permite cuando la base de datos está vacía. Los archivos adjuntos no se transfieren en el JSON y deberán subirse de nuevo. ¿Continuar?'))return;syncState('Importando…',false,true);const {data:response,error}=await cloud.rpc('import_initial_activities',{p_activities:data.tasks.map(migrate)});if(error)throw error;collapsedActivities.clear();await reloadActivities(true);tasks.forEach(t=>collapsedActivities.add(String(t.id)));persistCollapsed();render();alert('Importadas '+response+' actividades. Recuerda volver a subir los anexos originales.')}catch(err){syncState('Error de importación',true);alert('Error al importar: '+messageError(err))}e.target.value=''};
function printWindow(title,content,css,landscape=false){
 const w=window.open('','_blank');
 if(!w){alert('Permite ventanas emergentes para exportar el PDF.');return}
 const page=landscape?'A4 landscape':'A4 portrait';
 w.document.open();
 w.document.write(`<!doctype html><html lang="es"><head><meta charset="utf-8"><title>${esc(title)}</title><style>
 *{box-sizing:border-box}body{font-family:Arial,sans-serif;color:#18243b;margin:0;font-size:11px}
 @page{size:${page};margin:9mm}
 ${css}
 </style></head><body>${content}<script>window.onload=()=>setTimeout(()=>window.print(),500);<\/script></body></html>`);
 w.document.close();
}
function pdf(){
 const wi=weekInfo(),tr=(k,v)=>`<tr><th>${esc(k)}</th><td>${esc(v??'—')}</td></tr>`;
 const body=tasks.map(t=>{
  const current=t.steps[6]?'Completado':names[Math.max(0,t.steps.findIndex(x=>!x))];
  return `<section class="activity"><h2>Anexo ${esc(t.annex)} · ${esc(t.title)}</h2><table>${tr('Semana de alta',t.weekStart+' al '+t.weekEnd)}${tr('Etapa actual',current)}${tr('Estado',status(t))}${tr('Inicio tentativo',t.start)}${tr('Final tentativo',t.end)}${tr('Actividad previa',t.before?task(t.before)?.annex||t.before:'Ninguna')}${tr('Actividad posterior',t.after?task(t.after)?.annex||t.after:'Ninguna')}${t.reviewers?tr('Revisores',t.reviewers):''}${t.reviewAnnex?tr('Código de revisión',t.reviewAnnex):''}${t.authorizer?tr('Autorizó',t.authorizer):''}${tr('Avance de obra',t.progress+' %')}${tr('Verificación',t.verification+' %')}${t.attachments.length?tr('Documentos',t.attachments.map(a=>a.name).join(', ')):''}${t.completedDate?tr('Fecha de compleción',t.completedDate):''}</table></section>`;
 }).join('');
 const content=`<h1>Actividades Obra DYDEM</h1><p>Semana ${wi.week} · ${wi.start} al ${wi.end} · Reporte generado ${new Date().toLocaleDateString('es-MX')}</p><p>Total: ${tasks.length}</p>${body}`;
 const css=`h1{font-size:19px}h2{font-size:12px}.activity{border:1px solid #bdc8d8;border-radius:5px;padding:9px;margin:12px 0;break-inside:avoid}table{width:100%;border-collapse:collapse}td,th{border:1px solid #cfd8e4;padding:5px 7px;text-align:left;vertical-align:top}th{background:#edf1f7;width:35%}`;
 printWindow('DYDEM - Reporte de actividades',content,css);
}
function pdfTimeline(){
 const wi=weekInfo(),d=timelineData(),days=d.total;
 // Fit both axes. Compact mode is selected when full-height cards would be too small.
 const pageW=1040,pageH=700;
 const naturalWidth=Math.max(880,days*76);
 const fullHeight=105+tasks.length*54,smallHeight=105+tasks.length*31;
 const fullScale=Math.min(pageW/naturalWidth,pageH/fullHeight);
 const compact=fullScale<0.67 && tasks.length>0;
 const naturalHeight=compact?smallHeight:fullHeight;
 const scale=Math.min(1,pageW/naturalWidth,pageH/naturalHeight);
 const body=`<div class="sheet"><div class="scaled" style="width:${naturalWidth}px;transform:scale(${scale});--dot-inverse-scale:${(1/scale).toFixed(5)}"><h1>Cronograma de obra DYDEM</h1><p>Semana ${wi.week} · ${wi.start} al ${wi.end} · ${tasks.length} actividades · Generado ${new Date().toLocaleDateString('es-MX')}</p>${timelineHTML(true,compact)}</div></div>`;
 const css=`
 @media print{*{-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important;color-adjust:exact!important}}
 .sheet{width:275mm;height:185mm;overflow:hidden;position:relative}.scaled{transform-origin:top left}
 h1{font-size:21px;margin:0 0 4px}p{font-size:12px;margin:0 0 12px}
 .tl-reference-grid{min-width:0!important;width:100%;font-family:Arial,sans-serif}
 .tl-reference-grid{border:1px solid #89939e!important;box-sizing:border-box;overflow:hidden}
 .tl-head-ref{height:72px!important;border-bottom:0!important}
 .tl-weeks-ref{height:32px!important}
 .tl-days-ref{height:40px!important}
 .tl-day-ref{box-sizing:border-box;border-right:1px solid #737d89!important;border-bottom:1px solid #737d89!important}
 .tl-day-ref:last-child{border-right:0!important}
 .tl-today-continuous{position:absolute;top:32px;bottom:0;border-left:4px solid #04bc71;z-index:7;pointer-events:none}
 .tl-head-ref{height:82px;position:relative}.tl-weeks-ref{height:32px;display:flex}
 .tl-week-ref{background:#d9edff!important;border-right:2px solid #8c9cab;text-align:left;font-size:22px;padding-left:6px}
 .tl-week-ref:nth-child(even){background:#fff!important}
 .tl-days-ref{height:40px;display:grid;grid-template-columns:repeat(var(--day-count),minmax(0,1fr))}
 .tl-day-ref{font-size:12px;text-align:center;padding-top:10px;border-right:1px solid #aaa;background:#d9edff!important;white-space:nowrap}
 .tl-day-ref.week-blue{background:#d9edff!important}.tl-day-ref.week-white{background:#fff!important}.tl-day-ref.is-today{background:#60d6a0!important;font-weight:bold}
 .tl-today-tag{display:none}.tl-row-ref{position:relative;height:108px;border-bottom:1px solid #bbb}
 .tl-row-cells{position:absolute;inset:0;display:grid;grid-template-columns:repeat(var(--day-count),minmax(0,1fr))}
 .tl-background-cell{border-right:1px solid #aaa;background:#fff!important}.tl-background-cell.week-blue{background:#d9edff!important}.tl-background-cell.week-white{background:#fff!important}
 .tl-background-cell.week-start{border-left:2px solid #999}
 .tl-project-card{position:absolute;top:15px;height:77px;min-width:68px;border:3px solid #777;background:white!important;border-radius:9px;z-index:3;padding:8px;display:flex;flex-direction:column;justify-content:space-between;overflow:hidden}
 .activity-status-dot{display:inline-block;width:12px;height:12px;min-width:12px;min-height:12px;flex:0 0 12px;transform:scale(var(--dot-inverse-scale,1));transform-origin:center center;position:relative;z-index:8;border-radius:50%;margin-right:7px;vertical-align:middle;border:1px solid #888;-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important}
 .tl-card-title{font-size:16px;font-weight:normal;white-space:nowrap;overflow:visible;display:flex;align-items:center;min-width:0;gap:4px}.tl-card-percent{font-size:14px}
 .tl-card-progress{height:10px;border-radius:9px;background:#bbb!important;overflow:hidden}.tl-card-progress>div{height:100%;background:#38b6f4!important}
 .tl-delay{position:absolute;top:15px;height:77px;z-index:2;border:3px solid #777;border-left:0;border-radius:0 9px 9px 0;background:#ee989e!important;display:flex;align-items:center;justify-content:center;gap:6px;font-size:13px;overflow:hidden;white-space:nowrap}
 .tl-delay-arrow{font-size:24px}.tl-actual-marker{display:none}.tl-today-ref{position:absolute;top:0;bottom:0;border-left:4px solid #04bc71;z-index:6}
 .tl-annex{display:inline-block;flex-shrink:0;font-weight:750;white-space:nowrap;background:#fff;border-radius:3px;padding:0 2px;color:#172033}.tl-title-text{display:inline-block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}.tl-card-link{display:inline-flex!important;align-items:center;gap:4px;min-width:0;max-width:100%;overflow:visible!important}.tl-project-card{overflow:visible!important}.tl-card-title{overflow:visible!important}.tl-card-progress{overflow:hidden}.tl-annex{position:relative;z-index:8}

 .tl-project-card.tl-pending{background:#ffd69c!important;border-color:#d92f32!important;top:24px;height:59px}
 .tl-project-card.tl-pending .tl-card-progress{background:#ffc4c4!important}
 .tl-project-card.tl-pending .tl-card-progress>div{background:#d92f32!important}
 .tl-project-card.tl-finished{background:#c5f0d3!important;border-color:#15965c!important}
 .tl-project-card.tl-finished .tl-card-progress{background:#9edcb6!important}
 .tl-project-card.tl-finished .tl-card-progress>div{background:#15965c!important}
 .tl-compact .tl-project-card.tl-pending{top:13px;height:36px}
 ${compact?`.tl-compact .tl-row-ref{height:61px}.tl-compact .tl-project-card{top:8px;height:47px;padding:6px}.tl-compact .tl-delay{top:8px;height:47px}.tl-compact .tl-card-title{font-size:15px}.tl-compact .tl-card-progress{height:8px}`:''}

 .tl-project-card.tl-pending{background:#ffd69c!important;border-color:#d92f32!important;top:24px;height:59px}
 .tl-project-card.tl-pending .tl-card-progress{background:#ffc4c4!important}
 .tl-project-card.tl-pending .tl-card-progress>div{background:#d92f32!important}
 .tl-project-card.tl-finished{background:#c5f0d3!important;border-color:#15965c!important}
 .tl-project-card.tl-finished .tl-card-progress{background:#9edcb6!important}
 .tl-project-card.tl-finished .tl-card-progress>div{background:#15965c!important}
 .tl-compact .tl-project-card.tl-pending{top:13px;height:36px}

 /* Mitad de separación vertical también en el cronograma PDF */
 .tl-row-ref{height:54px}
 .tl-project-card,.tl-delay{top:6px;height:40px;padding:3px 6px;border-width:2px}
 .tl-project-card.tl-pending{top:10px;height:30px}
 .tl-card-title{font-size:12px;line-height:1.15}
 .tl-card-percent{font-size:9px;line-height:1.05}
 .tl-card-progress{height:5px}
 .tl-project-card.tl-pending .tl-card-percent{display:none}
 .tl-compact .tl-row-ref{height:31px}
 .tl-compact .tl-project-card,.tl-compact .tl-delay{top:3px;height:24px;padding:2px 4px;border-width:1px}
 .tl-compact .tl-project-card.tl-pending{top:5px;height:20px}
 .tl-compact .tl-card-title{font-size:11px;line-height:1.1}
 .tl-compact .tl-card-progress{height:4px}
 `;
 printWindow('DYDEM - Cronograma horizontal a color',body,css,true);
}

$('pdf').onclick=pdf;$('pdf-timeline').onclick=pdfTimeline;
// Arranque sin datos de ejemplo: la base de datos es la fuente única de verdad.
render();
initializeOnline();