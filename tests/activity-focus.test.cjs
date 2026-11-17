const test=require('node:test');
const assert=require('node:assert/strict');
const focus=require('../dydem-activity-focus.js');
const activity=patch=>({id:1,annex:'43_5',title:'Instalación eléctrica',progress:0,end:'2026-11-16',steps:[true,true,true,false,false,false,false],...patch});

test('a task due today is not overdue; unfinished past work is overdue',()=>{
 assert.equal(focus.overdue(activity({}), '2026-11-17'),true);
 assert.equal(focus.overdue(activity({end:'2026-11-17'}), '2026-11-17'),false);
 assert.equal(focus.overdue(activity({end:'2026-11-18'}), '2026-11-17'),false);
});
test('physical completion with pending documentation is closure, never overdue',()=>{
 const t=activity({progress:100});
 assert.equal(focus.closure(t),true);
 assert.equal(focus.overdue(t,'2026-11-17'),false);
 const complete=activity({progress:100,steps:Array(7).fill(true)});
 assert.equal(focus.closure(complete),false);
 assert.equal(focus.overdue(complete,'2026-11-17'),false);
 assert.equal(focus.matchesFilter(complete,'approval',{pendingApproval:true}),false);
});
test('a recorded completed work stage also prevents a misleading delay warning',()=>{
 const t=activity({steps:[true,true,true,true,false,false,false]});
 assert.equal(focus.closure(t),true);
 assert.equal(focus.overdue(t,'2026-11-17'),false);
 assert.equal(focus.stage(t),4);
});
test('missing or invalid end dates are not classified as delays',()=>{
 for(const end of ['',null,'2026-02-30','2026-13-01','2026-1-5'])assert.equal(focus.overdue(activity({end}),'2026-11-17'),false);
 assert.equal(focus.validDate('2028-02-29'),true);
 assert.equal(focus.validDate('2026-02-29'),false);
});
test('today follows Mexico City across the UTC midnight boundary',()=>{
 assert.equal(focus.todayISO(new Date('2026-11-17T03:30:00Z')),'2026-11-16');
 assert.equal(focus.todayISO(new Date('2026-11-17T06:30:00Z')),'2026-11-17');
});
test('search matches the annex, number and accented title without requiring accents',()=>{
 const t=activity({});
 assert.equal(focus.matchesSearch(t,'43_5'),true);
 assert.equal(focus.matchesSearch(t,'  electrica  '),true);
 assert.equal(focus.matchesSearch(t,'1'),true);
 assert.equal(focus.matchesSearch(t,'fontanería'),false);
});
test('approval filter uses the existing readiness/assignment decision, not the global role',()=>{
 const t=activity({});
 assert.equal(focus.matchesFilter(t,'approval',{pendingApproval:true}),true);
 assert.equal(focus.matchesFilter(t,'approval',{pendingApproval:false}),false);
 assert.equal(focus.matchesFilter(t,'all',{pendingApproval:false}),true);
});
test('filters and summaries do not alter stored workflow data',()=>{
 const t=activity({progress:100}),before=JSON.stringify(t);
 for(const filter of Object.keys(focus.filters))focus.matchesFilter(t,filter,{today:'2026-11-17',pendingApproval:true});
 focus.stage(t);focus.matchesSearch(t,'electrica');
 assert.equal(JSON.stringify(t),before);
});
