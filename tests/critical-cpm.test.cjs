// Examples behind the in-app explanation, evaluated against the real engine.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../dydem-critical.js'),'utf8');
const env={};vm.createContext(env);
vm.runInContext(source.slice(0,source.indexOf('function cgRenderSummary(')),env);
const compute=env.computeCriticalCPM;
const row=(id,start,end,project_id='obra')=>({id,project_id,data:{start,end,progress:0,annex:'47_'+id}});
const day=date=>Date.parse(date+'T00:00:00Z')/86400000;

test('parallel 5- and 3-day work followed by a 2-day joint test: slack 0, 2, 0',()=>{
 const rows=[row(1,'2026-11-01','2026-11-05'),row(2,'2026-11-01','2026-11-03'),row(3,'2026-11-01','2026-11-02')];
 const r=compute(rows,new Map([[3,{predecessors:[1,2]}]]));
 assert.equal(r.finish,day('2026-11-07'));
 assert.equal(r.byId.get(1).duration,5);assert.equal(r.byId.get(1).slack,0);assert.equal(r.byId.get(1).critical,true);
 assert.equal(r.byId.get(2).slack,2);assert.equal(r.byId.get(2).lateStart,day('2026-11-03'));assert.equal(r.byId.get(2).critical,false);
 assert.equal(r.byId.get(3).earlyStart,day('2026-11-06'));assert.equal(r.byId.get(3).slack,0);assert.equal(r.byId.get(3).critical,true);
 assert.equal(r.provisional,false);
});
test('inclusive duration and planned start act as a not-before constraint',()=>{
 const r=compute([row(1,'2026-11-01','2026-11-02'),row(2,'2026-11-10','2026-11-10')],new Map([[2,{predecessors:[1]}]]));
 assert.equal(r.byId.get(2).duration,1);
 assert.equal(r.byId.get(2).earlyStart,day('2026-11-10'));
 assert.equal(r.byId.get(1).slack,7);
});
test('slack is relative to the shared finish across included projects',()=>{
 const r=compute([row(1,'2026-11-01','2026-11-10','A'),row(2,'2026-11-01','2026-11-03','B')],new Map());
 assert.equal(r.byId.get(2).slack,7);
 assert.equal(r.finish,day('2026-11-10'));
 assert.equal(r.provisional,true);
});
test('excluded predecessors do not constrain the calculation and flag provisional data',()=>{
 const r=compute([row(1,'2026-11-01','2026-11-20'),row(2,'2026-11-01','2026-11-03')],new Map([[1,{included:false}],[2,{predecessors:[1]}]]));
 assert.equal(r.finish,day('2026-11-03'));assert.equal(r.byId.get(1).slack,null);
 assert.equal(r.byId.get(1).critical,false);assert.equal(r.missingLinks,1);assert.equal(r.provisional,true);
});
test('missing dates and cycles do not produce a positive float classification',()=>{
 const missing=compute([row(1,'','')],new Map());
 assert.equal(missing.byId.get(1).slack,null);assert.equal(missing.provisional,true);
 const cycle=compute([row(1,'2026-11-01','2026-11-02'),row(2,'2026-11-01','2026-11-02')],new Map([[1,{predecessors:[2]}],[2,{predecessors:[1]}]]));
 assert.equal(cycle.cyclic,true);assert.equal(cycle.criticalCount,0);assert.equal(cycle.byId.get(1).slack,null);
});
test('changing physical progress does not change the current CPM dates or float',()=>{
 const rows=[row(1,'2026-11-01','2026-11-05'),row(2,'2026-11-01','2026-11-03')];
 const a=compute(rows,new Map());rows[1].data.progress=100;
 const b=compute(rows,new Map());
 assert.equal(a.byId.get(2).slack,b.byId.get(2).slack);assert.equal(a.finish,b.finish);
});
