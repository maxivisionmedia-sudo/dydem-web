/* Project deletion: open a summary, then explicitly confirm. */
let projectDeleteTarget=null,projectDeleteBusy=false;
async function openProjectDelete(){
 if(!isAdmin()||!projectRecords.some(p=>p.id===PROJECT_ID)||projectDeleteBusy)return;
 if(saveBusy||attachmentUploadBusy){alert('Espera a que termine el guardado o la carga de archivos.');return}
 const dialog=$('project-delete-dialog');
 projectDeleteTarget={id:PROJECT_ID,name:projectName()};
 $('project-delete-title').textContent='¿Eliminar «'+projectDeleteTarget.name+'»?';
 $('project-delete-summary').textContent='Consultando el contenido del proyecto…';
 $('project-delete-error').textContent='';$('project-delete-confirm').disabled=true;
 $('project-delete-confirm').textContent='Sí, eliminar todo';
 dialog.showModal();$('project-delete-cancel').focus();
 const target=projectDeleteTarget;
 try{
  const {data,error}=await cloud.rpc('dydem_project_delete_preview',{pid:target.id});
  if(error)throw error;
  if(projectDeleteTarget!==target||!dialog.open)return;
  if(!data||data.project_id!==target.id||data.name!==target.name)throw Error('El proyecto cambió. Cierra esta ventana y vuelve a seleccionarlo.');
  $('project-delete-summary').textContent=data.activities+' actividades, '+data.comments+
   ' notas o dudas, '+data.files+' archivos adjuntos y '+data.history+' registros de historial.'+
   (data.external_links?' Se quitarán también las dependencias hacia estas actividades desde '+data.external_links+' actividades de otros proyectos.':'')+
   (isDirty()?' Los cambios locales sin guardar de este proyecto también se descartarán.':'');
  $('project-delete-confirm').textContent=data.deleting?'Reintentar eliminación':'Sí, eliminar todo';
  $('project-delete-confirm').disabled=false;
 }catch(err){$('project-delete-error').textContent='No se pudo preparar la eliminación: '+messageError(err)}
}
function cancelProjectDelete(){
 if(projectDeleteBusy)return;
 projectDeleteTarget=null;$('project-delete-dialog').close();$('project-delete').focus();
}
async function confirmProjectDelete(){
 if(projectDeleteBusy||!projectDeleteTarget||!isAdmin())return;
 const target={...projectDeleteTarget};
 if(target.id!==PROJECT_ID){cancelProjectDelete();return}
 projectDeleteBusy=true;$('project-delete-confirm').disabled=true;$('project-delete-cancel').disabled=true;
 $('project-delete-error').textContent='';
 let deleted=false;
 try{
  for(let attempt=0;attempt<100;attempt++){
   $('project-delete-summary').textContent='Eliminando el contenido de «'+target.name+'»…';
   const {data,error}=await cloud.functions.invoke('manage-projects',{body:{
    action:'delete-project',project_id:target.id,expected_name:target.name,confirmed:true}});
   if(error){let details;try{details=await error.context?.json()}catch(_){}throw Error(details?.error||messageError(error))}
   if(!data?.ok||data.project_id!==target.id)throw Error(data?.error||'El servidor no confirmó la eliminación.');
   if(data.done){deleted=true;break}
  }
  if(!deleted)throw Error('La eliminación sigue pendiente. Pulsa «Reintentar eliminación» para continuar.');
  closeAttachmentPreview();
  for(const t of tasks)collapsedActivities.delete(String(t.id));persistCollapsed();
  tasks=[];commentsByActivity.clear();commentDrafts.clear();commentFileRefsDrafts.clear();
  pendingAttachmentIntents.clear();pendingFileRegistrations.clear();lastSynced.clear();revisions.clear();openStageByActivity.clear();
  criticalActivities=[];criticalConfiguration.clear();criticalSelectedId=null;selectedActivityId=null;
  criticalMode=false;$('critical-path-panel').hidden=true;$('project-users-panel').hidden=true;
  $('project-create-form').hidden=true;activityListFilter='all';$('search').value='';
  if(subscription){await cloud.removeChannel(subscription);subscription=null}
  if(refreshTimer){clearInterval(refreshTimer);refreshTimer=null}
  if(refreshDelay){clearTimeout(refreshDelay);refreshDelay=null}
  PROJECT_ID=null;storeSet(PROJECT_SELECTION_KEY,'');projectDeleteTarget=null;
  $('project-delete-dialog').close();
  await loadProjects();
  if(projectRecords.length){await reloadActivities(true);startRealtime()}
  syncState('Proyecto «'+target.name+'» eliminado con su contenido.');
  if(projectRecords.length)$('project-select').focus();else $('project-new').focus();
 }catch(err){
  if(deleted){syncState('Proyecto eliminado. Recarga la página para actualizar la lista.',true)}
  else{
   $('project-delete-error').textContent=messageError(err);
   $('project-delete-confirm').textContent='Reintentar eliminación';
   try{await loadProjects()}catch(_){}
  }
 }finally{
  projectDeleteBusy=false;$('project-delete-confirm').disabled=false;$('project-delete-cancel').disabled=false;
 }
}
$('project-delete').addEventListener('click',openProjectDelete);
$('project-delete-cancel').addEventListener('click',cancelProjectDelete);
$('project-delete-confirm').addEventListener('click',confirmProjectDelete);
$('project-delete-dialog').addEventListener('cancel',event=>{event.preventDefault();cancelProjectDelete()});
