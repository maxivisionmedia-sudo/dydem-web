-- Transactional integration check. Uses synthetic rows only, then rolls back.
begin;
do $$
declare pid uuid:=gen_random_uuid();other_pid uuid:=gen_random_uuid();admin_id uuid;viewer_id uuid;
 job jsonb;summary jsonb;outcome jsonb;blocked boolean;before_projects bigint;before_activities bigint;
 aid bigint:=-900000000001;gone_aid bigint:=-900000000002;other_aid bigint:=-900000000003;
begin
 select id into admin_id from public.profiles where role='admin' and active limit 1;
 select id into viewer_id from public.profiles where role<>'admin' and active limit 1;
 if admin_id is null or viewer_id is null then raise exception 'Test requires existing admin and non-admin profiles';end if;
 select count(*) into before_projects from public.projects;
 select count(*) into before_activities from public.activities;
 if exists(select 1 from public.activities where id in(aid,gone_aid,other_aid)) then raise exception 'Test IDs already in use';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated')::text,true);
 insert into public.projects(id,name) values(pid,'__TEST_DELETE_ONLY__'),(other_pid,'__TEST_KEEP_ONLY__');
 insert into public.activities(id,project_id,data,annex,deleted_at) values
  (aid,pid,'{}','test1',null),(gone_aid,pid,'{}','test2',now()),(other_aid,other_pid,'{}','test3',null);
 insert into public.activity_history(activity_id,action,new_data) values(aid,'create','{}'),(gone_aid,'create','{}'),(other_aid,'create','{}');
 insert into public.activity_comments(project_id,activity_id,body) values(pid,aid,'Synthetic test note');
 insert into public.activity_upload_intents(id,project_id,activity_id,uploaded_by,file_name,storage_name,file_size,storage_path)
 values(gen_random_uuid(),pid,aid,admin_id,'test.txt','test.txt',1,pid::text||'/'||aid||'/test.txt');
 insert into public.proposal_upload_intents(id,project_id,activity_id,uploaded_by,file_name,storage_name,file_size,storage_path)
 values(gen_random_uuid(),pid,aid,admin_id,'test.txt','test.txt',1,pid::text||'/'||aid||'/review-test.txt');
 insert into public.dydem_project_members(project_id,user_id) values(pid,viewer_id),(other_pid,viewer_id);
 insert into public.dydem_critical_config(activity_id,predecessors) values(aid,'{}'),(other_aid,array[aid]);
 insert into public.annex_counters(week_code,last_used) values(pid::text||':2099-S01',2),(other_pid::text||':2099-S01',1);

 summary:=public.dydem_project_delete_preview(pid);
 if (summary->>'activities')::int<>2 or (summary->>'history')::int<>2 or (summary->>'comments')::int<>1 or (summary->>'external_links')::int<>1 then
  raise exception 'Preview does not include all records: %',summary;end if;
 if exists(select 1 from public.projects where id=pid and deletion_started_at is not null) then raise exception 'Preview changed project';end if;
 blocked:=false;
 begin perform public.dydem_begin_project_delete(pid,'__TEST_DELETE_ONLY__',false);exception when others then blocked:=true;end;
 if not blocked then raise exception 'Confirmation was not required';end if;
 blocked:=false;
 begin perform public.dydem_begin_project_delete(pid,'Wrong project',true);exception when others then blocked:=true;end;
 if not blocked then raise exception 'Expected project name was not checked';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'role','authenticated')::text,true);
 blocked:=false;
 begin perform public.dydem_project_delete_preview(pid);exception when insufficient_privilege then blocked:=true;end;
 if not blocked then raise exception 'Viewer accessed deletion preview';end if;
 blocked:=false;
 begin perform public.dydem_begin_project_delete(pid,'__TEST_DELETE_ONLY__',true);exception when insufficient_privilege then blocked:=true;end;
 if not blocked then raise exception 'Viewer started deletion';end if;
 perform set_config('request.jwt.claims','{}',true);
 blocked:=false;
 begin perform public.dydem_project_delete_preview(pid);exception when insufficient_privilege then blocked:=true;end;
 if not blocked then raise exception 'Anonymous access was accepted';end if;
 if has_function_privilege('authenticated','public.dydem_project_delete_step(uuid,uuid)','execute')
 or has_function_privilege('authenticated','dydem_private.project_delete_step(uuid,uuid)','execute')
 or has_function_privilege('anon','public.dydem_begin_project_delete(uuid,text,boolean)','execute') then
  raise exception 'Deletion grants are too broad';end if;
 if not has_function_privilege('service_role','public.dydem_project_delete_step(uuid,uuid)','execute') then raise exception 'Service cannot finish deletion';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated')::text,true);
 if not dydem_private.storage_project_writable(pid::text||'/file.txt') then raise exception 'Active project unexpectedly blocks files';end if;
 job:=public.dydem_begin_project_delete(pid,'__TEST_DELETE_ONLY__',true);
 if public.dydem_begin_project_delete(pid,'__TEST_DELETE_ONLY__',true)->>'token' is distinct from job->>'token' then raise exception 'Retry is not idempotent';end if;
 if dydem_private.storage_project_writable(pid::text||'/file.txt') then raise exception 'Deleting project accepts files';end if;
 blocked:=false;
 begin update public.activities set data='{"title":"changed"}' where id=aid;exception when sqlstate '55000' then blocked:=true;end;
 if not blocked then raise exception 'Deleting project accepts edits';end if;
 blocked:=false;
 begin perform public.create_activity('Synthetic new activity',pid);exception when sqlstate '55000' then blocked:=true;end;
 if not blocked then raise exception 'Deleting project accepts new activities';end if;
 blocked:=false;
 begin perform public.dydem_project_delete_step(pid,gen_random_uuid());exception when insufficient_privilege then blocked:=true;end;
 if not blocked then raise exception 'Invalid deletion token was accepted';end if;

 outcome:=public.dydem_project_delete_step(pid,(job->>'token')::uuid);
 if not (outcome->>'done')::boolean then raise exception 'Purge did not finish';end if;
 if exists(select 1 from public.projects where id=pid)
 or exists(select 1 from public.activities where project_id=pid)
 or exists(select 1 from public.activity_history where activity_id in(aid,gone_aid))
 or exists(select 1 from public.activity_comments where project_id=pid)
 or exists(select 1 from public.activity_upload_intents where project_id=pid)
 or exists(select 1 from public.proposal_upload_intents where project_id=pid)
 or exists(select 1 from public.dydem_project_members where project_id=pid)
 or exists(select 1 from public.dydem_critical_config where activity_id in(aid,gone_aid) or aid=any(predecessors))
 or exists(select 1 from public.annex_counters where starts_with(week_code,pid::text||':')) then
  raise exception 'Project data remained after deletion';end if;
 if not exists(select 1 from public.activities where id=other_aid)
 or not exists(select 1 from public.activity_history where activity_id=other_aid)
 or not exists(select 1 from public.dydem_project_members where project_id=other_pid)
 or not exists(select 1 from public.annex_counters where starts_with(week_code,other_pid::text||':')) then
  raise exception 'Another project was affected';end if;
 if (select count(*) from public.projects)<>before_projects+1 or (select count(*) from public.activities)<>before_activities+1 then
  raise exception 'Unexpected row count';end if;
 if not (public.dydem_project_delete_step(pid,(job->>'token')::uuid)->>'done')::boolean then raise exception 'Completed purge not idempotent';end if;
end $$;
rollback;
select 'project_delete_transaction_tests_passed' as result;
