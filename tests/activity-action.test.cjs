// Exercise the actual summary and approval rules without a browser or database.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const focus=require('../dydem-activity-focus.js');
const source=fs.readFileSync(path.join(__dirname,'../dydem.js'),'utf8');
const slice=source.slice(source.indexOf('const approvalStageKey='),source.indexOf('async function applyApprovalResponse('));
function context(role='viewer'){
 const env={activityFocus:focus,names:['Propuesta','Revisión','Autorizado','Avance de Obra','Verificación','Evidencia','Finalizado'],
  currentAccount:{id:'self',role,active:true},availableResponsibles:[{id:'self',display_name:'Yo'},{id:'other',display_name:'Ana'}],
  isSignedIn:()=>true,isAdmin:()=>role==='admin',
  requiredDates:t=>!!t.start&&!!t.end&&t.end>=t.start,
  esc:s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};
 vm.createContext(env);vm.runInContext(slice,env);return env;
}
const activity=patch=>({id:17,annex:'47_1',title:'Ductería',start:'2026-11-17',end:'2026-11-20',progress:0,
 steps:[true,true,false,false,false,false,false],responsibles:{review:[],authorization:['self','other'],verification:[]},
 approvals:{review:[],authorization:[],verification:[]},...patch});

for(const role of ['admin','viewer','custom']){
 test(role+': offers the same approval shortcut to an assigned, ready responsible',()=>{
  const env=context(role),t=activity({}),before=JSON.stringify(t);
  assert.equal(env.needsMyApproval(t),true);
  const action=env.activityNextAction(t);
  assert.equal(action.stage,2);assert.equal(action.mine,true);
  assert.match(action.text,/Requiere tu confirmación en Autorización/);
  assert.match(env.activityFocusHTML(t),/data-open-activity-stage="2"/);
  assert.equal(JSON.stringify(t),before);
 });
}
test('a future authorization is not offered before review is complete',()=>{
 const env=context(),t=activity({steps:[true,false,false,false,false,false,false]});
 assert.equal(env.needsMyApproval(t),false);
 assert.equal(env.activityNextAction(t).stage,1);
 assert.equal(env.activityNextAction(t).mine,false);
});
test('after my approval, the summary names the remaining responsible',()=>{
 const env=context(),t=activity({approvals:{authorization:['self']}});
 assert.equal(env.needsMyApproval(t),false);
 assert.match(env.activityNextAction(t).text,/Esperando a Ana/);
});
test('unassigned authorization directs the administrator to assignment',()=>{
 const env=context('admin'),t=activity({responsibles:{authorization:[]}});
 assert.equal(env.needsMyApproval(t),false);
 assert.match(env.activityNextAction(t).text,/Asignar responsables/);
});
test('finished activities have no shortcut suggesting another action',()=>{
 const env=context(),t=activity({steps:Array(7).fill(true),progress:100});
 assert.equal(env.activityNextAction(t).text,'Actividad finalizada');
 assert.doesNotMatch(env.activityFocusHTML(t),/data-open-activity-stage/);
});
test('summary escapes names and annexes supplied by users',()=>{
 const env=context();env.availableResponsibles[1].display_name='<img src=x onerror=alert(1)>';
 const html=env.activityFocusHTML(activity({annex:'"><img src=x>',approvals:{authorization:['self']}}));
 assert.doesNotMatch(html,/<img/);assert.match(html,/&lt;img/);
});
