const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require.resolve('../dydem-project-delete.js'),'utf8');
function ui({admin=true,busy=false,previewError=false}={}){
 const elements=new Map(),calls=[];
 const $=id=>{
  if(!elements.has(id))elements.set(id,{hidden:true,disabled:false,textContent:'',open:false,
   addEventListener(){},focus(){},showModal(){this.open=true},close(){this.open=false}});
  return elements.get(id);
 };
 const context=vm.createContext({$,isAdmin:()=>admin,PROJECT_ID:'project-a',projectRecords:[{id:'project-a'}],
  projectName:()=>'<Project A>',saveBusy:busy,attachmentUploadBusy:false,alert:message=>calls.push(['alert',message]),
  isDirty:()=>false,messageError:e=>e.message,
  cloud:{rpc:async(name,args)=>{calls.push([name,args]);return previewError?{error:{message:'No access'}}:
   {data:{project_id:'project-a',name:'<Project A>',activities:4,comments:2,files:1,history:8,external_links:1}}},
   functions:{invoke:async()=>{calls.push(['destructive']);return {error:{message:'Simulated interruption'}}}}},
  loadProjects:async()=>calls.push(['loadProjects'])});
 vm.runInContext(source+'\nglobalThis.ui={openProjectDelete,cancelProjectDelete,confirmProjectDelete};',context);
 return {context,$,calls,api:context.ui};
}
test('opening delete performs only a preview; Cancel never starts deletion',async()=>{
 const f=ui();await f.api.openProjectDelete();
 assert.equal(f.$('project-delete-dialog').open,true);
 assert.equal(f.$('project-delete-confirm').disabled,false);
 assert.match(f.$('project-delete-summary').textContent,/4 actividades/);
 assert.match(f.$('project-delete-title').textContent,/<Project A>/);
 assert.deepEqual(f.calls.map(c=>c[0]),['dydem_project_delete_preview']);
 f.api.cancelProjectDelete();await f.api.confirmProjectDelete();
 assert.equal(f.$('project-delete-dialog').open,false);
 assert.equal(f.calls.some(c=>c[0]==='destructive'),false);
});
test('confirmation is unavailable if the preview could not be obtained',async()=>{
 const f=ui({previewError:true});await f.api.openProjectDelete();
 assert.equal(f.$('project-delete-confirm').disabled,true);
 assert.match(f.$('project-delete-error').textContent,/No access/);
 assert.equal(f.calls.some(c=>c[0]==='destructive'),false);
});
test('delete is unavailable to non-admins and while an upload or save runs',async()=>{
 const viewer=ui({admin:false});await viewer.api.openProjectDelete();assert.deepEqual(viewer.calls,[]);
 const busy=ui({busy:true});await busy.api.openProjectDelete();assert.equal(busy.calls[0][0],'alert');
 assert.equal(busy.$('project-delete-dialog').open,false);
});
test('only the second action starts deletion; errors retain a retry button',async()=>{
 const f=ui();await f.api.openProjectDelete();await f.api.confirmProjectDelete();
 assert.equal(f.calls.filter(c=>c[0]==='destructive').length,1);
 assert.equal(f.$('project-delete-dialog').open,true);
 assert.equal(f.$('project-delete-confirm').disabled,false);
 assert.equal(f.$('project-delete-confirm').textContent,'Reintentar eliminación');
});
test('empty project picker keeps New project accessible to the admin',()=>{
 const f=ui();const app=fs.readFileSync(require.resolve('../dydem.js'),'utf8');
 const picker=app.slice(app.indexOf('function renderProjectPicker()'),app.indexOf('async function loadProjects()'));
 Object.assign(f.context,{projectRecords:[],currentProject:()=>({}),isSignedIn:()=>true,criticalMode:false,esc:String});
 vm.runInContext(picker+'\nrenderProjectPicker();',f.context);
 assert.equal(f.$('project-new').hidden,false);assert.equal(f.$('project-switcher').hidden,false);
 assert.equal(f.$('project-delete').hidden,true);assert.equal(f.$('project-members-manage').hidden,true);
 assert.equal(f.$('project-select').disabled,true);assert.equal(f.$('project-workspace').hidden,true);
});
