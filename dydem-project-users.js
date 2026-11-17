/* DYDEM · Usuarios y acceso a proyectos (solo Administración).
  La aplicación muestra el editor; las reglas se verifican en Supabase. */
let usersPanelProjectId=null;
async function openProjectUsersPanel(){
 if(!isAdmin())return;
 const panel=$('project-users-panel');
 if(!panel)return;
 if(!panel.hidden&&usersPanelProjectId===PROJECT_ID){panel.hidden=true;return}
 panel.hidden=false;usersPanelProjectId=PROJECT_ID;
 const label=$('project-users-title'),list=$('project-users-list'),status=$('project-users-status');
 label.textContent='Usuarios de '+projectName();
 list.innerHTML='<p class="muted">Cargando usuarios y permisos…</p>';
 status.textContent='';
 try{
  const projectId=PROJECT_ID;
  const [users,memberRows]=await Promise.all([
   cloud.from('profiles').select('id,email,display_name,role,active,removed_at').is('removed_at',null).order('display_name',{ascending:true}),
   cloud.from('dydem_project_members').select('user_id').eq('project_id',projectId)
  ]);
  if(users.error)throw users.error;
  if(memberRows.error)throw memberRows.error;
  if(projectId!==PROJECT_ID||panel.hidden)return;
  const members=new Set((memberRows.data||[]).map(x=>x.user_id));
  const accounts=(users.data||[]).filter(u=>u.active);
  const admins=accounts.filter(x=>x.role==='admin'),others=accounts.filter(x=>x.role!=='admin');
  $('project-users-admins').textContent=admins.length?
   'Administradores (acceso automático a todos los proyectos): '+admins.map(x=>x.display_name||x.email).join(', '):
   'Los administradores siempre tienen acceso automático.';
  list.innerHTML=others.length?others.map(u=>`<label class="project-users-entry">
   <input type="checkbox" name="project-user-member" value="${esc(u.id)}" ${members.has(u.id)?'checked':''}>
   <span><b>${esc(u.display_name||u.email)}</b><small>${esc(u.email)} · ${esc(roleLabel(u.role))}</small></span>
  </label>`).join(''):'<p class="muted">No hay otros usuarios activos disponibles para asignar.</p>';
  $('project-users-description').textContent=
    'Marca las personas que podrán consultar este proyecto. Sus permisos de edición siguen definidos por el rol general. Para retirar a un responsable de actividades, primero reasigna sus aprobaciones.';
 }catch(err){list.innerHTML='';status.textContent='No fue posible obtener los usuarios: '+messageError(err)}
}
$('project-members-manage').addEventListener('click',openProjectUsersPanel);
$('project-users-cancel').onclick=()=>{
 $('project-users-panel').hidden=true;usersPanelProjectId=null;$('project-users-status').textContent='';
};
$('project-users-form').onsubmit=async event=>{
 event.preventDefault();if(!isAdmin()||usersPanelProjectId!==PROJECT_ID)return;
 const form=event.currentTarget,save=$('project-users-save'),status=$('project-users-status');
 const projectId=PROJECT_ID,selected=[...form.querySelectorAll('input[name="project-user-member"]:checked')].map(x=>x.value);
 save.disabled=true;status.textContent='Guardando usuarios autorizados…';
 try{
  const {data,error}=await cloud.rpc('dydem_set_project_users',{pid:projectId,ids:selected});
  if(error)throw error;
  if(!data?.ok||String(data.project_id)!==projectId)throw Error('El servidor no confirmó los permisos.');
  const success='Acceso actualizado: '+data.members+' usuario(s) asignado(s), más todos los administradores.';
  await openProjectUsersPanelRefresh();
  $('project-users-status').textContent=success;
 }catch(err){status.textContent='No se pudieron guardar los accesos: '+messageError(err)}
 finally{save.disabled=false}
};
async function openProjectUsersPanelRefresh(){
 if(!$('project-users-panel').hidden&&isAdmin()){
  $('project-users-panel').hidden=true;
  await openProjectUsersPanel();
 }
}
