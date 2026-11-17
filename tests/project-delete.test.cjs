const {test}=require('node:test');
const assert=require('node:assert/strict');
const id='10000000-0000-4000-8000-000000000001';
const origin='https://maxivisionmedia-sudo.github.io';
async function fixture(options={}){
 const {createProjectDeletionHandler}=await import('../supabase/functions/manage-projects/handler.mjs');
 const calls=[];
 let steps=0;
 const scoped={auth:{getUser:async()=>({data:{user:options.invalidSession?null:{id:'admin'}},error:null})},
  rpc:async(name,args)=>{
   calls.push({name,args});
   if(name==='is_dydem_admin')return {data:options.viewer?false:true};
   if(name==='dydem_begin_project_delete')return options.startError?{error:{message:'Nombre cambiado'}}:{data:{ok:true,token:'job-token',done:!!options.alreadyGone}};
   throw Error('Unexpected scoped call');
  }};
 const admin={rpc:async(name,args)=>{
  calls.push({name,args});steps++;
  if(options.paths||steps===1)return {data:{ok:true,done:false,paths:options.paths||[id+'/123/file.pdf']}};
  return {data:{ok:true,done:true}};
 },storage:{from:bucket=>({remove:async paths=>{calls.push({name:'storage.remove',bucket,paths});return options.storageError?{error:{message:'Storage unavailable'}}:{error:null}}})}};
 const handle=createProjectDeletionHandler({url:'url',anon:'anon',secret:'secret',origins:new Set([origin]),
  createClient:(_url,key)=>key==='secret'?admin:scoped});
 const request=(changes={},headers={})=>new Request('https://example.test/manage-projects',{
  method:'POST',headers:{Origin:origin,Authorization:'Bearer user-token','Content-Type':'application/json',...headers},
  body:JSON.stringify({action:'delete-project',project_id:id,expected_name:'Test project',confirmed:true,...changes})});
 return {handle,request,calls};
}
test('requires explicit confirmation before starting any deletion',async()=>{
 const f=await fixture();const r=await f.handle(f.request({confirmed:false}));
 assert.equal(r.status,400);assert.equal(f.calls.some(c=>c.name==='dydem_begin_project_delete'),false);
});
test('viewer cannot begin or perform a deletion',async()=>{
 const f=await fixture({viewer:true});const r=await f.handle(f.request());
 assert.equal(r.status,403);assert.equal(f.calls.length,1);
});
test('invalid session and disallowed origin cannot reach database operations',async()=>{
 const f=await fixture({invalidSession:true});
 assert.equal((await f.handle(f.request())).status,401);
 assert.equal((await f.handle(f.request({}, {Origin:'https://attacker.test'}))).status,403);
 assert.deepEqual(f.calls,[]);
});
test('deletes only server-provided paths and finishes after Storage succeeds',async()=>{
 const f=await fixture();const r=await f.handle(f.request({paths:['another-project/file']}));
 assert.equal(r.status,200);assert.equal((await r.json()).done,true);
 assert.deepEqual(f.calls.map(c=>c.name),['is_dydem_admin','dydem_begin_project_delete','dydem_project_delete_step','storage.remove','dydem_project_delete_step']);
 assert.deepEqual(f.calls.find(c=>c.name==='storage.remove').paths,[id+'/123/file.pdf']);
});
test('Storage failure does not finalize the database purge and can be retried',async()=>{
 const f=await fixture({storageError:true});const r=await f.handle(f.request());
 assert.equal(r.status,502);assert.match((await r.json()).error,/Reintentar/);
 assert.equal(f.calls.filter(c=>c.name==='dydem_project_delete_step').length,1);
});
test('fails closed if a returned path escapes the selected project',async()=>{
 const f=await fixture({paths:['another-project/file.pdf']});const r=await f.handle(f.request());
 assert.equal(r.status,502);assert.equal(f.calls.some(c=>c.name==='storage.remove'),false);
});
test('a renamed project needs a fresh confirmation',async()=>{
 const f=await fixture({startError:true});const r=await f.handle(f.request());
 assert.equal(r.status,409);assert.equal(f.calls.some(c=>c.name==='dydem_project_delete_step'),false);
});
test('retry after a completed deletion is idempotent',async()=>{
 const f=await fixture({alreadyGone:true});const r=await f.handle(f.request());
 assert.equal((await r.json()).done,true);assert.equal(f.calls.length,2);
});
test('large jobs return progress without claiming completion',async()=>{
 const f=await fixture({paths:[id+'/file.pdf']});const r=await f.handle(f.request());
 assert.equal(r.status,202);assert.equal((await r.json()).done,false);
 assert.equal(f.calls.filter(c=>c.name==='storage.remove').length,10);
});
