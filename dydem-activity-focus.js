/* Presentation-only activity filters. No changes to stages, dates or permissions. */
(function(root){
 'use strict';
 const filters=Object.freeze({all:'Todas',approval:'Requieren mi aprobación',overdue:'Obra atrasada',closure:'Cierre pendiente'});
 const progress=t=>Math.max(0,Math.min(100,Number(t.progress)||0));
 const finished=t=>t.steps?.[6]===true;
 const workDone=t=>t.steps?.[3]===true||progress(t)===100;
 function validDate(value){
  if(!/^\d{4}-\d{2}-\d{2}$/.test(String(value||'')))return false;
  const stamp=Date.parse(value+'T00:00:00Z');
  return Number.isFinite(stamp)&&new Date(stamp).toISOString().slice(0,10)===value;
 }
 function todayISO(now=new Date()){
  const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'America/Mexico_City',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now);
  const value=type=>parts.find(p=>p.type===type).value;
  return value('year')+'-'+value('month')+'-'+value('day');
 }
 const closure=t=>!finished(t)&&workDone(t);
 const overdue=(t,today=todayISO())=>!finished(t)&&!workDone(t)&&validDate(t.end)&&t.end<today;
 function stage(t){
  if(finished(t))return 6;
  return [0,1,2,3,4,5,6].find(i=>!t.steps?.[i]);
 }
 const normalized=value=>String(value??'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
 const matchesSearch=(t,query)=>normalized(`${t.id} ${t.annex||''} ${t.title||''}`).includes(normalized(query).trim());
 function matchesFilter(t,filter,{today=todayISO(),pendingApproval=false}={}){
  if(filter==='approval')return !finished(t)&&pendingApproval;
  if(filter==='overdue')return overdue(t,today);
  if(filter==='closure')return closure(t);
  return true;
 }
 const api=Object.freeze({filters,progress,finished,workDone,validDate,todayISO,closure,overdue,stage,matchesSearch,matchesFilter});
 if(typeof module==='object'&&module.exports)module.exports=api;
 else root.DydemActivityFocus=api;
})(typeof globalThis==='undefined'?this:globalThis);
