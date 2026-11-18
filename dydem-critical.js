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
function criticalLegendHTML(){
 return `<h3 id="critical-legend-title">Cómo leer el Gantt</h3>
 <dl class="critical-terms"><div><dt>Flechas de dependencia</dt><dd>Selecciona una barra o su actividad. Las flechas azules llegan desde sus predecesoras y las moradas apuntan a sus sucesoras. Se dibujan entre barras visibles.</dd></div>
  <div><dt>Duración · días naturales</dt><dd>Días programados entre el inicio y el final previstos, contando ambos. Del 10 al 14 son 5 días; incluye sábados, domingos y festivos. No indica días restantes.</dd></div>
  <div><dt>Holgura total</dt><dd>Margen para desplazar una actividad sin retrasar el fin global calculado. Se obtiene restando el inicio temprano al inicio tardío. Puede desplazar actividades posteriores y se comparte con su cadena: no se suma entre actividades.</dd></div>
  <div><dt><i class="critical-key key-critical" aria-hidden="true"></i>Crítica · holgura 0</dt><dd>Un retraso desplaza el fin global, si las demás fechas y duraciones se mantienen. Puede haber varias rutas críticas. La importancia del trabajo y su porcentaje de avance no determinan esta etiqueta.</dd></div>
  <div><dt><i class="critical-key key-included" aria-hidden="true"></i>No crítica · holgura mayor que 0</dt><dd>Tiene margen en el cálculo actual. La barra azul indica inclusión; confirma su holgura y revisa si el resultado es provisional.</dd></div>
  <div><dt><i class="critical-key key-blocked" aria-hidden="true"></i>Bloqueada</dt><dd>Está excluida del cálculo CPM. No significa que la obra esté detenida. Una actividad sin fechas o sin cálculo tampoco se clasifica como no crítica.</dd></div>
  <div><dt>Fin calculado · Fin CPM</dt><dd>Fecha más tardía de terminación calculada entre las actividades incluidas de todos los proyectos. La holgura se refiere a ese final común, no al plazo particular de cada proyecto.</dd></div>
  <div><dt>Predecesoras · Dep.</dt><dd>Trabajos que deben terminar antes de comenzar esta actividad. La relación actual es fin a inicio: la siguiente puede empezar al día siguiente, sin desfases adicionales.</dd></div>
  <div><dt>Cálculo provisional</dt><dd>No hay dependencias, faltan fechas, existen vínculos a actividades excluidas o sin fechas, o hay un ciclo. Los resultados dependen de las fechas y relaciones registradas.</dd></div>
 </dl>
 <p class="critical-legend-note"><b>Referencias visuales:</b> línea verde = hoy; barra tenue discontinua = fechas previstas originales cuando difieren del cálculo. Anexo identifica la actividad; Sem. identifica la semana. En el PDF, Avance es el porcentaje de obra registrado.</p>
 <details class="critical-calculation-help"><summary>Cómo se calcula la ruta crítica (CPM)</summary>
  <ol>
   <li><b>Duración:</b> final previsto − inicio previsto + 1 día.</li>
   <li><b>Inicio temprano:</b> la fecha más tardía entre el inicio previsto y el día siguiente al final temprano de todas las predecesoras incluidas y con fechas válidas. El final temprano suma la duración, contando el primer día.</li>
   <li><b>Fechas tardías:</b> desde el fin global se recorre la red hacia atrás. Cada actividad debe terminar antes del inicio tardío de sus sucesoras; si no tiene sucesoras calculables, puede terminar en el fin global.</li>
   <li><b>Holgura:</b> inicio tardío − inicio temprano, equivalente a final tardío − final temprano. Holgura 0 = crítica; holgura positiva = no crítica.</li>
  </ol>
  <p><b>Ejemplo:</b> dos trabajos paralelos duran 5 y 3 días. Una prueba de 2 días espera a ambos. El conjunto termina el día 7: el trabajo de 5 días y la prueba tienen holgura 0; el trabajo de 3 días tiene holgura de 2 días.</p>
  <p>Este cálculo usa días naturales, fechas previstas y dependencias. No descuenta trabajo ejecutado ni considera disponibilidad de cuadrillas, materiales o equipos. Tampoco calcula holgura negativa frente a una fecha límite contractual. Las fechas previstas de las actividades se conservan.</p>
 </details>`;
}
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
function drawCriticalLinks(chart,node){
 const bars=new Map([...chart.querySelectorAll('.critical-bar')].map(bar=>[Number(bar.dataset.criticalPick),bar]));
 const origin=chart.getBoundingClientRect(), paths=[];
 function connect(from,to,color){
  if(!bars.has(from)||!bars.has(to))return;
  const a=bars.get(from).getBoundingClientRect(), b=bars.get(to).getBoundingClientRect();
  const x=a.right-origin.left,y=a.top+a.height/2-origin.top;
  const target=b.left-origin.left+6,down=b.top>a.top;
  const tip=(down?b.top:b.bottom)-origin.top,base=tip+(down?-6:6);
  const line=`M${x} ${y} H${target} V${base}`;
  paths.push(`<path d="${line}" fill="none" stroke="white" stroke-width="4"/><path d="${line}" fill="none" stroke="${color}" stroke-width="2"/><path d="M${target-4} ${base} L${target} ${tip} L${target+4} ${base} Z" fill="${color}"/>`);
 }
 for(const id of node.effectiveDependencies)connect(id,node.id,'#12578a');
 for(const id of node.successors)connect(node.id,id,'#784191');
 chart.querySelector('.critical-links').innerHTML=paths.join('');
}
let criticalLinkObserver;
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
 const focus=result.byId.get(Number(criticalSelectedId));
 const previous=new Set(focus?.predecessors||[]);
 const startOf=n=>n.earlyStart??n.start??Infinity;
 const rows=[];
 for(const [pid,items] of byProject){
  if(!items.length)continue;
  rows.push(`<div class="critical-project-row"><div class="critical-project-name">${esc(projectLabel(pid))} · ${items.length} actividad${items.length===1?'':'es'}</div><div class="critical-project-rail"></div></div>`);
  items.sort((a,b)=>startOf(a)-startOf(b)||a.id-b.id);
  for(const n of items){
   const role=n===focus?'Seleccionada':previous.has(n.id)?'Predecesora':focus&&n.predecessors.includes(focus.id)?'Sucesora':'';
   const accent=role==='Seleccionada'?'#8a5400':role==='Predecesora'?'#12578a':'#784191';
   const color=n.critical?'is-critical':!n.included?'is-blocked':'';
   const selected=n.id===criticalSelectedId?'selected':'';
   const planned=trackRect(n.start,n.end);
   const effective=n.included?trackRect(n.earlyStart,n.earlyEnd):planned;
   const bar=effective?`<button type="button" class="critical-bar ${color}" data-critical-pick="${n.id}" style="left:${effective.left}px;width:${effective.width}px" title="${esc(n.t.annex)}: ${esc(n.t.title)} · ${esc(n.earlyStart!==null?'CPM '+cgISO(n.earlyStart)+' – '+cgISO(n.earlyEnd):'Excluida / sin fechas')}">${esc(n.t.annex)}${effective.width>110?' · '+esc(n.t.title):''}</button>`:'';
   const ghost=planned&&n.included&&n.earlyStart!==null&&n.earlyStart!==n.start?`<span class="critical-planned" title="Fechas tentativas originales" style="left:${planned.left}px;width:${planned.width}px"></span>`:'';
   const line=n.critical?'Crítica · Holgura: 0 días':!n.included?'Bloqueada':n.duration===null?'Sin fechas':n.slack===null?'Sin calcular':'Holgura: '+cgDigits(n.slack);
   rows.push(`<div class="critical-activity-row ${!n.included?'is-blocked':''} ${selected}" data-critical-row="${n.id}">
    <div class="critical-row-info"><input type="checkbox" data-critical-include="${n.id}" aria-label="Incluir actividad ${esc(n.t.annex)}" ${n.included?'checked':''}>
      <button type="button" class="critical-row-label" data-critical-pick="${n.id}" title="${esc(n.t.title)}">
       <b>${esc(n.t.annex)} · ${esc(n.t.title)}</b><small>${role?`<strong style="color:${accent}">${role}</strong> · `:""}<span>${esc(line)}</span>${n.duration!==null?'<span>Duración: '+cgDigits(n.duration)+'</span>':''}</small>
      </button>${n.critical?'<span class="critical-flag">CRÍTICA</span>':''}</div>
    <div class="critical-rail" data-critical-pick="${n.id}">${ghost}${bar}${markToday()}</div></div>`);
  }
 }
 const content=rows.join('')||'<p style="padding:18px">No hay actividades que coincidan con los filtros.</p>';
 container.innerHTML=`<div class="critical-chart" style="position:relative;--cg-day-width:${dayWidth}px;--cg-total-width:${span*dayWidth}px">
 <div class="critical-header"><div class="critical-header-caption">Orden por inicio · Selecciona una actividad para ver sus vínculos</div><div class="critical-day-header">${header}</div></div>
 ${content}<svg class="critical-links" aria-hidden="true" style="position:absolute;inset:0;width:100%;height:100%;pointer-events:none;z-index:2"></svg></div>`;
 criticalLinkObserver?.disconnect();
 if(focus){
  const chart=container.firstElementChild;
  const draw=()=>drawCriticalLinks(chart,focus);
  draw();
  if(typeof ResizeObserver!=='undefined'){criticalLinkObserver=new ResizeObserver(draw);criticalLinkObserver.observe(chart)}
 }
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
 <p class="muted">Proyecto: ${esc(projectLabel(node.project_id))} · Inicio previsto: ${esc(node.t.start||'Sin fecha')} · Final previsto: ${esc(node.t.end||'Sin fecha')}
 · Duración: ${node.duration!==null?cgDigits(node.duration)+(node.duration===1?' natural':' naturales'):'no disponible'}</p>
  ${[['Predecesoras',result.all.filter(n=>chosen.has(n.id))],['Sucesoras',result.all.filter(n=>n.predecessors.includes(node.id))]].map(([label,list])=>'<p><b>'+label+'</b> · '+(list.map(n=>esc(projectLabel(n.project_id)+' / '+n.t.annex+' · '+n.t.title)).join(' · ')||'Ninguna')+'</p>').join('')}
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
 renderCriticalGantt();
 if(e.detail===0)$('critical-gantt').querySelector('[data-critical-row="'+criticalSelectedId+'"] .critical-row-label')?.focus({preventScroll:true});
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
 // Reserve room for the explanatory footer without shrinking activity text.
 const cpm=computeCriticalCPM(criticalActivities,criticalConfiguration),DAY=28,ROWS=16;
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
     <footer class="cp-footer"><div class="cp-footer-top"><div class="cp-legend"><span><i class="cp-key-crit"></i> Crítica (holgura 0)</span>
       <span><i class="cp-key-normal"></i> Incluida</span>
       <span><i class="cp-key-block"></i> Bloqueada</span>
       <span><i class="cp-key-unknown"></i> Sin fechas</span></div>
       <span>${nodes.length} actividades de ${inPeriod.length} en este periodo · Página __PAGE__ de __TOTAL__</span></div>
       <p class="cp-reading-key"><b>Duración:</b> final previsto − inicio previsto + 1. <b>Holgura:</b> margen sin retrasar el fin global calculado. <b>Crítica:</b> holgura 0; <b>no crítica:</b> holgura mayor que 0.</p>
       <p class="cp-reading-key">Días naturales, incluidos fines de semana. CPM usa fechas y dependencias, no avance real ni recursos. Bloqueada = excluida del cálculo. Dep. = predecesoras. Avance = porcentaje de obra.</p></footer>
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
 .cp-footer{position:absolute;bottom:2mm;left:0;right:0;height:14mm;font-size:7pt;color:#52667e}
 .cp-footer-top{display:flex;justify-content:space-between;gap:4mm;align-items:center;line-height:1.25}
 .cp-footer-top>span{white-space:nowrap}.cp-legend{display:flex;gap:3mm;flex-wrap:wrap}
 .cp-reading-key{margin:1.3mm 0 0;font-size:7.2pt;line-height:1.25}
 .cp-legend span{white-space:nowrap}.cp-legend i{display:inline-block;vertical-align:middle;width:3mm;height:1.5mm;border:1px solid #7793b3;margin-right:.8mm}
 .cp-key-crit{background:#f5a7a7;border-color:#bb2c3b!important}.cp-key-normal{background:#9fccf5}
 .cp-key-block{background:#d4d9df;border-style:dashed!important}.cp-key-unknown{background:#f3e5c5}
 `;
 printWindow('DYDEM · Ruta crítica general · Gantt',html,css,true);
}

function printCriticalOverview(pageLimit){
 if(!isAdmin()||!criticalMode)return;
 const result=computeCriticalCPM(criticalActivities,criticalConfiguration);
 const startOf=n=>n.earlyStart??n.start;
 const endOf=n=>n.earlyEnd??n.end;
 const items=result.all.slice().sort((a,b)=>projectLabel(a.project_id).localeCompare(projectLabel(b.project_id),'es')||
  (startOf(a)??Infinity)-(startOf(b)??Infinity)||a.id-b.id);
 if(!items.length){alert('No hay actividades para exportar.');return}
 const pages=Math.min(pageLimit,items.length);
 const first=result.start,last=result.last,days=last-first+1;
 const left=748,width=652,chartX=day=>left+(day-first)*width/days;
 const measure=document.createElement('canvas').getContext('2d');
 function label(x,y,value,size,space,bold=false){
  const str=String(value);
  measure.font=(bold?'bold ':'')+size+'px Arial';
  const fit=measure.measureText(str).width>space?` textLength="${space}" lengthAdjust="spacingAndGlyphs"`:'';
  return `<text x="${x}" y="${y}" font-size="${size}" font-weight="${bold?'bold':'normal'}"${fit}>${esc(str)}</text>`;
 }
 const ticks=[];
 const stride=Math.max(7,Math.ceil(days/12/7)*7);
 const monday=first+(8-new Date(first*CG_DAY_MS).getUTCDay())%7;
 for(let day=monday;day<=last;day+=stride)ticks.push(day);
 const rowsPerPage=Math.ceil(items.length/pages);
 const rowHeight=Math.min(29,810/rowsPerPage),font=Math.min(14,rowHeight*.72);
 const sheets=Array.from({length:pages},(_,i)=>{
  const begin=Math.floor(i*items.length/pages),end=Math.floor((i+1)*items.length/pages);
  const rows=items.slice(begin,end);
  const height=42+rows.length*rowHeight;
  const grid=ticks.map(d=>`<line x1="${chartX(d)}" x2="${chartX(d)}" y1="25" y2="${height}" stroke="#cad5e1"/>`+
   (chartX(d)<1364?label(chartX(d)+2,17,cgDateText(d),12,40):'')).join('');
  const body=rows.map((n,j)=>{
   const y=36+j*rowHeight,baseline=y+rowHeight*.72;
   const a=startOf(n),b=endOf(n),valid=a!==null&&b!==null&&b>=a;
   const color=!n.included?'#718096':n.critical?'#ab2639':'#357cb4';
   const bar=valid?`<rect x="${chartX(a)}" y="${y+rowHeight*.25}" width="${width*(b-a+1)/days}" height="${rowHeight*.50}" fill="${color}"/>`:label(left+5,baseline,'Sin fechas válidas',font,width);
   return `<g data-activity="${n.id}"><line x1="0" x2="1400" y1="${y+rowHeight}" y2="${y+rowHeight}" stroke="#dce3e9"/>`+
    label(1,baseline,n.id,font,32)+label(36,baseline,projectLabel(n.project_id),font,76)+
    label(116,baseline,n.t.title||'Actividad',font,475)+label(598,baseline,n.predecessors.join(', ')||'—',font,144)+bar+'</g>';
  }).join('');
  return `<section><header><h1>DYDEM · Ruta crítica general</h1><b>Hoja ${i+1} de ${pages}</b></header>
   <p>${cgISO(first)} – ${cgISO(last)} · Actividades ${begin+1} a ${end} de ${items.length} · ${result.cyclic?'Dependencias circulares':result.provisional?'Cálculo provisional':'Fechas calculadas por CPM'}</p>
   <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1400 855" preserveAspectRatio="xMinYMin meet">
   ${label(1,17,'ID',13,32,true)}${label(36,17,'Proyecto',13,76,true)}${label(116,17,'Actividad',13,475,true)}${label(598,17,'Predecesoras (ID)',13,145,true)}${grid}${body}</svg>
   <footer><b style="color:#ab2639">■ Crítica</b>　<b style="color:#357cb4">■ Incluida</b>　<b style="color:#718096">■ Bloqueada</b>　·　Las predecesoras se identifican por su ID en cualquier hoja.</footer></section>`;
 }).join('');
 printWindow('DYDEM · Gantt completo',sheets,`@page{size:A4 landscape;margin:7mm}
 *{box-sizing:border-box;print-color-adjust:exact;-webkit-print-color-adjust:exact}
 body{margin:0;font-family:Arial,sans-serif}section{height:195mm;display:flex;flex-direction:column;break-inside:avoid}
 section+section{break-before:page;page-break-before:always}header{display:flex;justify-content:space-between;align-items:center}
 h1{font-size:14pt;margin:0}p,footer{font-size:8pt;margin:1.5mm 0}svg{width:100%;height:173mm;display:block}footer{margin-top:auto}`,true);
}
$('critical-print').onclick=()=>{
 const pages=Number($('critical-print-format')?.value);
 if([2,3,4].includes(pages))printCriticalOverview(pages);
 else printCriticalGanttPdf();
};
$('critical-legend').innerHTML=criticalLegendHTML();
