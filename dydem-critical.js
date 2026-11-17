/* DYDEM: proyectos separados y ruta crítica global.
 * Pantalla de administración. La autorización real la aplica Supabase:
 * dydem_create_project y dydem_set_critical_activity (RLS solo admin).
 */
const CG_DAY_MS=86400000;
const cgDateDay=value=>{
 if(!/^\d{4}-\d{2}-\d{2}$/.test(String(value||'')))return null;
 const n=Date.parse(value+'T00:00:00Z');
 return Number.isFinite(n)?Math.round(n/CG_DAY_MS):null;
};
const cgISO=day=>new Date(day*CG_DAY_MS).toISOString().slice(0,10);
const cgDateText=day=>{const d=new Date(day*CG_DAY_MS);return String(d.getUTCDate()).padStart(2,'0')+'/'+String(d.getUTCMonth()+1).padStart(2,'0')};
const cgDigits=days=>Math.round(days)+' día'+(Math.round(days)===1?'':'s');
function computeCriticalCPM(rows,configuration){
 const all=rows.map(r=>{
  const t=r.data||r,conf=configuration.get(Number(r.id))||{};
  const start=cgDateDay(t.start),end=cgDateDay(t.end),duration=start!==null&&end!==null&&end>=start?end-start+1:null;
  return {id:Number(r.id),project_id:r.project_id,t,conf,included:conf.included!==false,
   predecessors:Array.isArray(conf.predecessors)?conf.predecessors.map(Number):[],start,end,duration,
   earlyStart:null,earlyEnd:null,lateStart:null,lateEnd:null,slack:null,critical:false,successors:[],effectiveDependencies:[]};
 });
 const byId=new Map(all.map(n=>[n.id,n]));
 // Preserve previously entered Propuesta relationships as defaults.
 // "Solo después de" points to a predecessor; "Debe completarse antes"
 // points to a successor. An explicit critical configuration takes precedence.
 for(const n of all){
  if(configuration.has(n.id))continue;
  const predecessor=Number(n.t.after);
  if(Number.isSafeInteger(predecessor)&&predecessor>0&&byId.has(predecessor)&&
      byId.get(predecessor).project_id===n.project_id&&predecessor!==n.id)
   n.predecessors.push(predecessor);
  for(const candidate of all){
   if(candidate.id!==n.id&&candidate.project_id===n.project_id&&Number(candidate.t.before)===n.id)
    n.predecessors.push(candidate.id);
  }
  n.predecessors=[...new Set(n.predecessors)];
 }
 const selected=all.filter(n=>n.included),scheduled=selected.filter(n=>n.duration!==null),nodes=new Map(scheduled.map(n=>[n.id,n]));
 let missingLinks=0,links=0;
 for(const n of scheduled){
  n.effectiveDependencies=n.predecessors.filter(id=>{
   if(!nodes.has(id)){missingLinks++;return false}
   return true;
  });
  n.effectiveDependencies=[...new Set(n.effectiveDependencies)];
  links+=n.effectiveDependencies.length;
  for(const id of n.effectiveDependencies)nodes.get(id).successors.push(n.id);
 }
 const degrees=new Map(scheduled.map(n=>[n.id,n.effectiveDependencies.length]));
 const available=scheduled.filter(n=>degrees.get(n.id)===0).sort((a,b)=>a.start-b.start||a.id-b.id);
 const ordered=[];
 while(available.length){
  const n=available.shift();
  n.earlyStart=n.start;
  for(const p of n.effectiveDependencies){
   const parent=nodes.get(p);
   n.earlyStart=Math.max(n.earlyStart,parent.earlyEnd+1);
  }
  n.earlyEnd=n.earlyStart+n.duration-1;
  ordered.push(n);
  for(const id of n.successors){
   degrees.set(id,degrees.get(id)-1);
   if(degrees.get(id)===0)available.push(nodes.get(id));
  }
 }
 const cyclic=ordered.length!==scheduled.length;
 const end=ordered.length?Math.max(...ordered.map(n=>n.earlyEnd)):null;
 if(!cyclic&&end!==null){
  for(const n of ordered.slice().reverse()){
   n.lateStart=n.successors.length?Math.min(...n.successors.map(id=>nodes.get(id).lateStart-n.duration)):end-n.duration+1;
   n.lateEnd=n.lateStart+n.duration-1;
   n.slack=Math.max(0,n.lateStart-n.earlyStart);
   n.critical=n.slack===0;
  }
 }
 const criticalCount=scheduled.filter(n=>n.critical).length;
 const minStart=all.filter(n=>n.start!==null).map(n=>n.start).concat(ordered.map(n=>n.earlyStart)).filter(Number.isFinite);
 const maxEnd=all.filter(n=>n.end!==null).map(n=>n.end).concat(ordered.map(n=>n.earlyEnd)).filter(Number.isFinite);
 const today=cgDateDay(new Date().toISOString().slice(0,10));
 const timelineStart=minStart.length?Math.min(...minStart):today;
 const timelineEnd=maxEnd.length?Math.max(...maxEnd):today+27;
 return {all,byId,selected,scheduled,ordered,cyclic,links,missingLinks,criticalCount,
  omittedDates:selected.length-scheduled.length,finish:end,start:timelineStart,last:Math.max(timelineEnd,timelineStart+27),
  provisional:links===0||missingLinks>0||selected.length!==scheduled.length||cyclic};
}
function cgRenderSummary(result){
 const critical=result.criticalCount,days=result.finish!==null?cgDateText(result.finish):'Sin fechas';
 const stat=(number,label)=>`<div class="critical-stat"><strong>${esc(number)}</strong><small>${esc(label)}</small></div>`;
 $('critical-summary').innerHTML=stat(result.all.length,'Actividades de todos los proyectos')+
 stat(result.selected.length,'Incluidas en el Gantt')+
 stat(result.all.length-result.selected.length,'Bloqueadas')+
 stat(critical,'Actividades críticas')+
 stat(days,'Fin calculado')+
 `<div class="critical-stat" style="flex-basis:100%"><strong style="font-size:14px">${result.cyclic?'Revisar dependencias circulares':result.provisional?'Cálculo provisional':'Ruta crítica calculada'}</strong>
 <small>${result.links} dependencias válidas · ${result.omittedDates} actividades incluidas sin fechas completas${result.missingLinks?' · '+result.missingLinks+' vínculos a actividades bloqueadas o sin fechas':''}.
 ${result.links===0?'Añade dependencias para identificar una ruta crítica real.':''}</small></div>`;
}
function renderCriticalGantt(){
 if(!criticalMode||!isAdmin())return;
 const result=computeCriticalCPM(criticalActivities,criticalConfiguration);
 cgRenderSummary(result);
 const container=$('critical-gantt'),oldLeft=container.scrollLeft,oldTop=container.scrollTop;
 const query=$('critical-search').value.trim().toLowerCase();
 const showIncluded=$('critical-only-included').checked,onlyCritical=$('critical-only-critical').checked;
 const byProject=new Map(projectRecords.map(p=>[p.id,[]]));
 for(const n of result.all){
  if(showIncluded&&!n.included||onlyCritical&&!n.critical)continue;
  if(query&&!(''+n.id+' '+n.t.annex+' '+n.t.title+' '+projectLabel(n.project_id)).toLowerCase().includes(query))continue;
  if(!byProject.has(n.project_id))byProject.set(n.project_id,[]);
  byProject.get(n.project_id).push(n);
 }
 const left=result.start-(new Date(result.start*CG_DAY_MS).getUTCDay()+6)%7;
 const right=result.last+6-(new Date(result.last*CG_DAY_MS).getUTCDay()+6)%7;
 const span=Math.max(28,right-left+1),dayWidth=27;
 const weekdays=['Lu','Ma','Mi','Ju','Vi','Sa','Do'];
 const header=Array.from({length:span},(_,i)=>{
  const date=new Date((left+i)*CG_DAY_MS),month=date.toLocaleString('es-MX',{month:'short',timeZone:'UTC'});
  return `<div class="critical-day ${Math.floor(i/7)%2===0?'week-shade':''}" title="${cgISO(left+i)}"><span>${esc(weekdays[i%7])}</span><strong>${String(date.getUTCDate()).padStart(2,'0')}</strong>${i%7===0?`<span>${esc(month)}</span>`:''}</div>`;
 }).join('');
 const markToday=()=>{
  const now=cgDateDay(new Date().toISOString().slice(0,10));
  return now!==null&&now>=left&&now<=right?`<span class="critical-today" style="left:${(now-left+.5)*dayWidth}px" title="Hoy"></span>`:'';
 };
 const trackRect=(start,end)=>{
  if(start===null||end===null||start>end)return null;
  return {left:(start-left)*dayWidth,width:Math.max(dayWidth,(end-start+1)*dayWidth)};
 };
 const rows=[];
 for(const [pid,items] of byProject){
  if(!items.length)continue;
  rows.push(`<div class="critical-project-row"><div class="critical-project-name">${esc(projectLabel(pid))} · ${items.length} actividad${items.length===1?'':'es'}</div><div class="critical-project-rail"></div></div>`);
  for(const n of items){
   const color=n.critical?'is-critical':!n.included?'is-blocked':'';
   const selected=n.id===criticalSelectedId?'selected':'';
   const planned=trackRect(n.start,n.end);
   const effective=n.included?trackRect(n.earlyStart,n.earlyEnd):planned;
   const bar=effective?`<button type="button" class="critical-bar ${color}" data-critical-pick="${n.id}" style="left:${effective.left}px;width:${effective.width}px" title="${esc(n.t.annex)}: ${esc(n.t.title)} · ${esc(n.earlyStart!==null?'CPM '+cgISO(n.earlyStart)+' – '+cgISO(n.earlyEnd):'Excluida / sin fechas')}">${esc(n.t.annex)}${effective.width>110?' · '+esc(n.t.title):''}</button>`:'';
   const ghost=planned&&n.included&&n.earlyStart!==null&&n.earlyStart!==n.start?`<span class="critical-planned" title="Fechas tentativas originales" style="left:${planned.left}px;width:${planned.width}px"></span>`:'';
   const line=n.critical?'Crítica · Holgura 0':!n.included?'Bloqueada':n.duration===null?'Sin fechas':n.slack===null?'Sin calcular':'Holgura '+cgDigits(n.slack);
   rows.push(`<div class="critical-activity-row ${!n.included?'is-blocked':''} ${selected}" data-critical-row="${n.id}">
    <div class="critical-row-info"><input type="checkbox" data-critical-include="${n.id}" aria-label="Incluir actividad ${esc(n.t.annex)}" ${n.included?'checked':''}>
      <button type="button" class="critical-row-label" data-critical-pick="${n.id}" title="${esc(n.t.title)}">
       <b>${esc(n.t.annex)} · ${esc(n.t.title)}</b><small>${esc(line)}${n.duration!==null?' · '+cgDigits(n.duration):''}</small>
      </button>${n.critical?'<span class="critical-flag">CRÍTICA</span>':''}</div>
    <div class="critical-rail" data-critical-pick="${n.id}">${ghost}${bar}${markToday()}</div></div>`);
  }
 }
 const content=rows.join('')||'<p style="padding:18px">No hay actividades que coincidan con los filtros.</p>';
 container.innerHTML=`<div class="critical-chart" style="--cg-day-width:${dayWidth}px;--cg-total-width:${span*dayWidth}px">
 <div class="critical-header"><div class="critical-header-caption">Proyecto · Anexo · Actividad</div><div class="critical-day-header">${header}</div></div>
 ${content}</div>`;
 container.scrollLeft=oldLeft;container.scrollTop=oldTop;
 renderCriticalInspector(result);
}
function renderCriticalInspector(result=computeCriticalCPM(criticalActivities,criticalConfiguration)){
 const node=result.byId.get(Number(criticalSelectedId));
 const box=$('critical-config-panel');
 if(!node){box.innerHTML='<h3>Dependencias y selección</h3><p class="muted">Selecciona una actividad de cualquier proyecto en el Gantt. Podrás decidir si se incluye y cuáles son sus actividades predecesoras.</p>';return}
 const peers=result.all.filter(n=>n.id!==node.id).sort((a,b)=>projectLabel(a.project_id).localeCompare(projectLabel(b.project_id))||String(a.t.annex).localeCompare(String(b.t.annex)));
 const chosen=new Set(node.predecessors);
 const options=peers.map(n=>`<option value="${n.id}" ${chosen.has(n.id)?'selected':''}>${esc(projectLabel(n.project_id))} · ${esc(n.t.annex)} · ${esc(String(n.t.title||'').slice(0,95))}${!n.included?' (bloqueada)':''}</option>`).join('');
 box.innerHTML=`<h3>Configurar · ${esc(node.t.annex)} · ${esc(node.t.title)}</h3>
 <p class="muted">Proyecto: ${esc(projectLabel(node.project_id))} · Inicio: ${esc(node.t.start||'Sin fecha')} · Final: ${esc(node.t.end||'Sin fecha')}
 · ${node.duration!==null?cgDigits(node.duration):'Duración no disponible'}</p>
 <form id="critical-edit-form">
 <label><input id="critical-edit-included" type="checkbox" ${node.included?'checked':''}> Incluir esta actividad en el Gantt global</label>
 <label for="critical-predecessors">Actividades predecesoras (deben terminar antes de empezar esta)</label>
 <select id="critical-predecessors" multiple size="${Math.min(9,Math.max(4,peers.length))}">${options}</select>
 <p class="muted">Mantén Ctrl (Windows) o Cmd (Mac) para seleccionar varias. Puedes vincular actividades de diferentes proyectos. Las relaciones ya capturadas en Propuesta se proponen automáticamente; puedes modificarlas aquí. Las bloqueadas se ignoran hasta volver a incluirlas.</p>
 <div class="critical-config-actions"><button class="btn" type="submit">Guardar inclusión y dependencias</button>
 <span id="critical-edit-status" role="status" class="muted">${node.critical?'En la ruta crítica calculada.':node.included?'Actividad incluida.':'Actividad bloqueada.'}</span></div>
 </form>`;
}
async function loadCriticalPath(){
 if(!isAdmin())return;
 $('critical-gantt').innerHTML='<p style="padding:18px">Consultando los proyectos y sus actividades…</p>';
 const [data,config]=await Promise.all([
  cloud.from('activities').select('id,project_id,data').is('deleted_at',null).order('id',{ascending:true}),
  cloud.from('dydem_critical_config').select('activity_id,included,predecessors')
 ]);
 if(data.error)throw data.error;
 if(config.error)throw config.error;
 criticalActivities=(data.data||[]).map(r=>({...r,id:Number(r.id)}));
 criticalConfiguration=new Map((config.data||[]).map(x=>[Number(x.activity_id),{included:x.included,predecessors:x.predecessors||[]}]));
 if(criticalSelectedId&&!criticalActivities.some(n=>n.id===Number(criticalSelectedId)))criticalSelectedId=null;
 renderCriticalGantt();
}
async function showCriticalPath(){
 if(!isAdmin())return;
 if(saveBusy){alert('Termina primero el guardado pendiente.');return}
 if(isDirty()&&!confirm('Hay cambios de actividades sin guardar. ¿Abrir el Gantt general sin guardarlos?'))return;
 criticalMode=true;$('project-workspace').hidden=true;$('critical-path-panel').hidden=false;
 $('project-create-form').hidden=true;$('critical-show').disabled=true;
 try{await loadProjects();await loadCriticalPath();syncState('Vista general de ruta crítica')}
 catch(e){$('critical-gantt').textContent='No se pudo cargar la ruta crítica: '+messageError(e);syncState('Error de ruta crítica',true)}
 finally{$('critical-show').disabled=false}
}
function closeCriticalPath(){
 criticalMode=false;$('critical-path-panel').hidden=true;$('project-workspace').hidden=false;
 renderProjectPicker();render();syncState('Proyecto: '+projectName());
}
$('project-select').onchange=event=>{selectProject(event.target.value).catch(err=>alert(messageError(err)))};
$('project-new').onclick=()=>{
 if(!isAdmin())return;
 $('project-create-form').hidden=!$('project-create-form').hidden;
 if(!$('project-create-form').hidden)$('project-create-name').focus();
};
$('project-create-cancel').onclick=()=>{$('project-create-form').hidden=true;$('project-create-error').textContent=''};
$('project-create-form').onsubmit=async e=>{
 e.preventDefault();if(!isAdmin())return;
 const btn=$('project-create-submit'),name=$('project-create-name').value.trim(),description=$('project-create-description').value.trim();
 if(isDirty()&&!confirm('Hay cambios locales pendientes. ¿Crear el proyecto y descartar esos cambios al abrirlo?'))return;
 btn.disabled=true;$('project-create-error').textContent='';
 try{
  const {data,error}=await cloud.rpc('dydem_create_project',{p_name:name,p_description:description});
  if(error)throw error;
  if(!data?.id)throw Error('El servidor no devolvió el proyecto creado.');
  await loadProjects();
  $('project-create-form').reset();$('project-create-form').hidden=true;
  await selectProject(String(data.id),true);
 }catch(err){$('project-create-error').textContent='No se pudo crear el proyecto: '+messageError(err)}
 finally{btn.disabled=false}
};
$('critical-show').onclick=()=>showCriticalPath();
$('critical-close').onclick=closeCriticalPath;
$('critical-refresh').onclick=async()=>{if(!isAdmin())return;try{await loadProjects();await loadCriticalPath()}catch(e){alert('No se pudo actualizar: '+messageError(e))}};
for(const name of ['critical-search','critical-only-included','critical-only-critical']){
 $(name).addEventListener(name==='critical-search'?'input':'change',()=>{if(criticalMode)renderCriticalGantt()});
}
$('critical-gantt').addEventListener('click',e=>{
 const picked=e.target.closest('[data-critical-pick]');
 if(!picked||!isAdmin())return;
 criticalSelectedId=Number(picked.dataset.criticalPick);
 $('critical-gantt').querySelectorAll('.critical-activity-row').forEach(el=>el.classList.toggle('selected',Number(el.dataset.criticalRow)===criticalSelectedId));
 renderCriticalInspector();
 $('critical-config-panel').scrollIntoView({behavior:'smooth',block:'nearest'});
});
async function cgSave(activityId,included,predecessors,feedback){
 const {data,error}=await cloud.rpc('dydem_set_critical_activity',{
  p_activity_id:Number(activityId),p_included:!!included,p_predecessors:predecessors.map(Number)
 });
 if(error)throw error;
 if(!data||Number(data.activity_id)!==Number(activityId))throw Error('No se confirmó la configuración');
 criticalConfiguration.set(Number(activityId),{included:data.included,predecessors:data.predecessors||[]});
 renderCriticalGantt();
 if(feedback&&$('critical-edit-status'))$('critical-edit-status').textContent=feedback;
}
$('critical-gantt').addEventListener('change',async e=>{
 const element=e.target.closest('input[data-critical-include]');
 if(!element||!isAdmin())return;
 const id=Number(element.dataset.criticalInclude),calculated=computeCriticalCPM(criticalActivities,criticalConfiguration);
 const old=criticalConfiguration.get(id)||{included:true,predecessors:calculated.byId.get(id)?.predecessors||[]};
 element.disabled=true;
 try{await cgSave(id,element.checked,old.predecessors,element.checked?'Actividad añadida al Gantt.':'Actividad bloqueada en el Gantt.')}
 catch(err){element.checked=!element.checked;element.disabled=false;alert('No se pudo modificar la inclusión: '+messageError(err))}
});
$('critical-config-panel').addEventListener('submit',async e=>{
 if(e.target.id!=='critical-edit-form'||!isAdmin())return;
 e.preventDefault();
 const id=Number(criticalSelectedId),included=$('critical-edit-included').checked;
 const select=$('critical-predecessors'),predecessors=[...select.selectedOptions].map(o=>Number(o.value));
 const btn=e.target.querySelector('button[type=submit]'),message=$('critical-edit-status');
 btn.disabled=true;message.textContent='Guardando dependencias…';
 try{await cgSave(id,included,predecessors,'Configuración guardada. Ruta crítica recalculada.')}
 catch(err){message.textContent='Error: '+messageError(err)}
 finally{btn.disabled=false}
});


function printCriticalGanttPdf(){
 if(!isAdmin())return;
 if(!criticalMode){alert('Abre la Ruta crítica general antes de exportarla.');return}
 const cpm=computeCriticalCPM(criticalActivities,criticalConfiguration),DAY=28,ROWS=17;
 const search=$('critical-search').value.trim().toLowerCase(),onlyIncluded=$('critical-only-included').checked,onlyCritical=$('critical-only-critical').checked;
 const visible=cpm.all.filter(n=>(!onlyIncluded||n.included)&&(!onlyCritical||n.critical)&&
 (!search||(`${n.id} ${n.t.annex||''} ${n.t.title||''} ${projectLabel(n.project_id)}`).toLowerCase().includes(search)));
 const offset=(new Date(cpm.start*CG_DAY_MS).getUTCDay()+6)%7;
 const zero=cpm.start-offset,last=cpm.last+6-(new Date(cpm.last*CG_DAY_MS).getUTCDay()+6)%7;
 const totalWeeks=Math.max(1,Math.ceil((last-zero+1)/DAY)),pages=[];
 const localToday=new Date();
 const today=Math.round(Date.UTC(localToday.getFullYear(),localToday.getMonth(),localToday.getDate())/CG_DAY_MS);
 const percent=x=>(x*100/DAY).toFixed(5);
 const range=(a,b,first)=>{
  if(a===null||b===null||a>b)return null;
  const low=Math.max(a,first),high=Math.min(b,first+DAY-1);
  return low<=high?{left:percent(low-first),width:percent(high-low+1),continuedLeft:a<first,continuedRight:b>first+DAY-1}:null;
 };
 const dateLabel=n=>cgDateText(n);
 const summarize=n=>{
  const label=n.critical?'CRÍTICA':!n.included?'Bloqueada':n.duration===null?'Sin fechas':n.slack===null?'Por calcular':'Holgura '+cgDigits(n.slack);
  const refs=n.predecessors.map(id=>cpm.byId.get(id)?.t.annex||String(id));
  return label+' · Avance '+Math.max(0,Math.min(100,Number(n.t.progress)||0))+'%'+(refs.length?' · Dep.: '+refs.join(', '):'');
 };
 const weekNumber=n=>{const dt=new Date(n*CG_DAY_MS);return weekInfo(new Date(dt.getUTCFullYear(),dt.getUTCMonth(),dt.getUTCDate())).week};
 for(let w=0;w<totalWeeks;w++){
  const start=zero+w*DAY,end=start+DAY-1;
  const inPeriod=visible.filter(n=>{
   const a=n.included&&n.earlyStart!==null?n.earlyStart:n.start;
   const b=n.included&&n.earlyEnd!==null?n.earlyEnd:n.end;
   return (a===null||b===null)?w===0:!!range(a,b,start);
  }).sort((a,b)=>projectLabel(a.project_id).localeCompare(projectLabel(b.project_id),'es')
   ||(a.earlyStart??a.start??Infinity)-(b.earlyStart??b.start??Infinity)||a.id-b.id);
  const groups=Math.max(1,Math.ceil(inPeriod.length/ROWS));
  for(let group=0;group<groups;group++){
   const nodes=inPeriod.slice(group*ROWS,(group+1)*ROWS);
   const weeks=Array.from({length:4},(_,i)=>`<div class="cp-week ${i%2?'cp-light':'cp-shade'}">Sem-${esc(weekNumber(start+i*7))} <span>${dateLabel(start+i*7)} – ${dateLabel(start+i*7+6)}</span></div>`).join('');
   const dates=Array.from({length:DAY},(_,i)=>{const day=start+i,todayFlag=day===today;
    return `<div class="cp-date ${Math.floor(i/7)%2?'cp-light':'cp-shade'} ${todayFlag?'cp-date-today':''}">${dateLabel(day).slice(0,2)}</div>`;
   }).join('');
   const bg=Array.from({length:DAY},(_,i)=>`<span class="cp-cell ${Math.floor(i/7)%2?'cp-light':'cp-shade'} ${i%7===0?'cp-boundary':''}"></span>`).join('');
   const rows=nodes.map(n=>{
    const a=n.included&&n.earlyStart!==null?n.earlyStart:n.start,b=n.included&&n.earlyEnd!==null?n.earlyEnd:n.end;
    const rect=range(a,b,start);
    const cls=n.critical?'cp-critical':!n.included?'cp-blocked':n.duration===null?'cp-undated':'cp-normal';
    const progress=Math.max(0,Math.min(100,Number(n.t.progress)||0));
    const rectHTML=rect?`<div class="cp-bar ${cls} ${rect.continuedLeft?'cp-carry-in':''} ${rect.continuedRight?'cp-carry-out':''}" style="left:${rect.left}%;width:${rect.width}%"><span class="cp-fill" style="width:${progress}%"></span></div>`:'';
    const note=!rect?'<span class="cp-nodate">Sin fechas válidas</span>':'';
    return `<div class="cp-row">
     <div class="cp-label"><b>${esc(projectLabel(n.project_id))} · ${esc(n.t.annex||n.id)}</b>
       <span class="cp-name">${esc(n.t.title||'Actividad')}</span><small>${esc(summarize(n))}</small></div>
     <div class="cp-track"><div class="cp-grid">${bg}</div>${rectHTML}${note}</div></div>`;
   }).join('')||'<div class="cp-empty">No hay actividades en este periodo con los filtros actuales.</div>';
   const partial=groups>1?` · Grupo ${group+1} de ${groups}`:'';
   const warning=cpm.cyclic?'Advertencia: hay dependencias circulares.':cpm.provisional?'Cálculo provisional: verifica fechas y dependencias.':'Ruta crítica calculada por CPM.';
   pages.push(`<section class="cp-sheet">
     <header class="cp-heading"><div><h1>DYDEM · Ruta crítica general</h1>
       <p>Gantt de todos los proyectos · ${dateLabel(start)} al ${dateLabel(end)} · 4 semanas por hoja</p></div>
       <aside>${esc(warning)}<br>Bloque ${w+1} de ${totalWeeks}${partial}</aside></header>
     <div class="cp-metrics">${cpm.selected.length} actividades incluidas · ${cpm.all.length-cpm.selected.length} bloqueadas · ${cpm.criticalCount} críticas · ${cpm.links} dependencias válidas · Fin CPM: ${cpm.finish===null?'Sin calcular':dateLabel(cpm.finish)}</div>
     <div class="cp-chart"><div class="cp-header"><div class="cp-caption">PROYECTO · ANEXO · ACTIVIDAD · DEPENDENCIAS</div>
       <div class="cp-calendar"><div class="cp-weeks">${weeks}</div><div class="cp-dates">${dates}</div></div></div>
       <div class="cp-rows">${rows}</div></div>
     <footer class="cp-footer"><div class="cp-legend"><span><i class="cp-key-crit"></i> Crítica (holgura 0)</span>
       <span><i class="cp-key-normal"></i> Incluida</span>
       <span><i class="cp-key-block"></i> Bloqueada</span>
       <span><i class="cp-key-unknown"></i> Sin fechas</span></div>
       <span>${nodes.length} actividades de ${inPeriod.length} en este periodo · Página __PAGE__ de __TOTAL__</span></footer>
    </section>`);
  }
 }
 const html=pages.map((html,i)=>html.replace('__PAGE__',String(i+1)).replace('__TOTAL__',String(pages.length))).join('');
 const css=`
 @page{size:A4 landscape;margin:7mm}
 *{box-sizing:border-box;-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important}
 html,body{margin:0!important;padding:0!important;font-family:Arial,Helvetica,sans-serif;color:#22344e;background:#fff!important}
 .cp-sheet{width:283mm;height:196mm;overflow:hidden;position:relative;page-break-inside:avoid;break-inside:avoid;background:white}
 .cp-sheet:not(:last-child){page-break-after:always;break-after:page}
 .cp-heading{height:18mm;display:flex;justify-content:space-between;align-items:flex-start;gap:5mm}
 .cp-heading h1{font-size:15pt;margin:.5mm 0 1mm}.cp-heading p{font-size:9pt;margin:0}
 .cp-heading aside{text-align:right;font-size:8pt;max-width:100mm;color:#536781;line-height:1.55}
 .cp-metrics{height:9mm;border-bottom:.6px solid #9cacc0;font-size:8.5pt;color:#33557b;padding:2mm 0}
 .cp-chart{margin-top:6mm;border:1px solid #b2c2d5;overflow:hidden}
 .cp-header,.cp-row{display:grid;grid-template-columns:80mm minmax(0,1fr)}
 .cp-header{height:17mm;border-bottom:1px solid #7c93b0}
 .cp-caption{font-size:8.3pt;font-weight:700;background:#edf4fc;padding:5mm 2mm;border-right:1px solid #8ca0b9}
 .cp-calendar{min-width:0}.cp-weeks{height:8mm;display:grid;grid-template-columns:repeat(4,minmax(0,1fr))}
 .cp-week{font-weight:700;font-size:8pt;padding:2mm 1mm;border-right:1px solid #859bb6;white-space:nowrap}
 .cp-week span{float:right;color:#586b81;font-size:6pt}
 .cp-dates{display:grid;grid-template-columns:repeat(28,minmax(0,1fr));height:9mm}
 .cp-date{text-align:center;padding:2.2mm 0;font-size:6.7pt;border-right:.5px solid #bac8d6}
 .cp-date-today{background:#70dbad!important}
 .cp-rows{width:100%}
 .cp-row{height:8mm;position:relative;break-inside:avoid;border-bottom:.4px solid #cbd7e3}
 .cp-label{overflow:hidden;background:#fafcff;display:flex;flex-direction:column;justify-content:center;padding:.5mm 1.2mm;border-right:1px solid #acbbcd}
 .cp-label b{font-size:7.3pt;line-height:1.12;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
 .cp-label .cp-name{font-size:7.1pt;line-height:1.15;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
 .cp-label small{font-size:5.8pt;color:#6d7889;line-height:1.1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .cp-track{position:relative;overflow:hidden}.cp-grid{position:absolute;inset:0;display:grid;grid-template-columns:repeat(28,minmax(0,1fr))}
 .cp-cell{border-right:.4px solid #b3bfd0}.cp-boundary{border-left:.7px solid #879bb5}
 .cp-shade{background:#daebfc}.cp-light{background:#fff}
 .cp-bar{position:absolute;z-index:2;top:1.5mm;bottom:1.5mm;min-width:0;border-radius:1mm;border:1.1pt solid #448ac7;background:#9fccf5;overflow:hidden}
 .cp-bar.cp-critical{background:#f5a7a7;border-color:#bb2c3b}
 .cp-bar.cp-blocked{background:#d4d9df;border-color:#89929d;border-style:dashed}
 .cp-bar.cp-undated{background:#f3e5c5;border-color:#d4a851}
 .cp-carry-in{border-left:0;border-top-left-radius:0;border-bottom-left-radius:0}
 .cp-carry-out{border-right:0;border-top-right-radius:0;border-bottom-right-radius:0}
 .cp-fill{position:absolute;bottom:0;left:0;top:65%;background:rgba(30,79,127,.35)}
 .cp-critical .cp-fill{background:rgba(170,32,48,.4)}
 .cp-nodate{font-size:7pt;color:#737f8e;position:absolute;top:2.2mm;left:2mm}
 .cp-empty{padding:8mm;text-align:center;color:#65778d;font-size:9pt}
 .cp-footer{position:absolute;bottom:2mm;left:0;right:0;display:flex;justify-content:space-between;gap:4mm;align-items:center;font-size:7pt;color:#52667e}
 .cp-footer>span{white-space:nowrap}.cp-legend{display:flex;gap:3mm;flex-wrap:wrap}
 .cp-legend span{white-space:nowrap}.cp-legend i{display:inline-block;vertical-align:middle;width:3mm;height:1.5mm;border:1px solid #7793b3;margin-right:.8mm}
 .cp-key-crit{background:#f5a7a7;border-color:#bb2c3b!important}.cp-key-normal{background:#9fccf5}
 .cp-key-block{background:#d4d9df;border-style:dashed!important}.cp-key-unknown{background:#f3e5c5}
 `;
 printWindow('DYDEM · Ruta crítica general · Gantt',html,css,true);
}

$('critical-print').onclick=printCriticalGanttPdf;
