-- Two UI steps: preview, then confirmation. Only the Edge Function's service
-- role can purge rows; Storage bytes are removed through the Storage API first.
alter table public.projects
 add column deletion_started_at timestamptz,
 add column deletion_token uuid,
 add constraint projects_deletion_state check ((deletion_started_at is null)=(deletion_token is null));

create schema if not exists dydem_private;
revoke all on schema dydem_private from public,anon;
grant usage on schema dydem_private to authenticated,service_role;

create function dydem_private.assert_project_writable(pid uuid)
returns void language plpgsql security definer set search_path='' as $$
declare started timestamptz;
begin
 select deletion_started_at into started from public.projects where id=pid for share;
 if not found then raise exception 'Proyecto no disponible' using errcode='23503';end if;
 if started is not null then raise exception 'El proyecto está en proceso de eliminación' using errcode='55000';end if;
end $$;

create function dydem_private.guard_project_write()
returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid;old_pid uuid;dep_pid uuid;
begin
 -- Removing predecessor references is safe, including when another project
 -- is being purged concurrently. Adding a reference always checks its target.
 if tg_table_name='dydem_critical_config' and tg_op='UPDATE' then
  if new.included=old.included and new.predecessors <@ old.predecessors then return new;end if;
 end if;
 if tg_table_name in ('activity_history','dydem_critical_config') then
  select project_id into pid from public.activities where id=new.activity_id;
 else
  pid:=(to_jsonb(new)->>'project_id')::uuid;
 end if;
 if tg_op='UPDATE' and to_jsonb(old) ? 'project_id' then
  old_pid:=(to_jsonb(old)->>'project_id')::uuid;
  if old_pid is distinct from pid then perform dydem_private.assert_project_writable(old_pid);end if;
 end if;
 perform dydem_private.assert_project_writable(pid);
 if tg_table_name='dydem_critical_config' then
  for dep_pid in select distinct project_id from public.activities where id=any(new.predecessors)
  loop perform dydem_private.assert_project_writable(dep_pid);end loop;
 end if;
 return new;
end $$;

do $$
declare tab text;
begin
 foreach tab in array array['activities','activity_comments','activity_history','activity_upload_intents',
  'proposal_upload_intents','dydem_project_members','dydem_critical_config'] loop
  execute format('create trigger zz_dydem_project_write_guard before insert or update on public.%I for each row execute function dydem_private.guard_project_write()',tab);
 end loop;
end $$;

-- The row share lock covers the Storage INSERT transaction. A concurrent
-- delete cannot finish between an upload's policy check and its object insert.
create function dydem_private.storage_project_writable(p_path text)
returns boolean language plpgsql security definer set search_path='' as $$
declare pid uuid;started timestamptz;
begin
 if auth.uid() is null then return false;end if;
 begin pid:=split_part(p_path,'/',1)::uuid;exception when invalid_text_representation then return false;end;
 if not public.dydem_has_project_access(pid) then return false;end if;
 select deletion_started_at into started from public.projects where id=pid for share;
 return found and started is null;
end $$;
create policy dydem_project_not_deleting_upload on storage.objects as restrictive
 for insert to authenticated
 with check(bucket_id<>'activity-attachments' or dydem_private.storage_project_writable(name));
create policy dydem_project_not_deleting_replace on storage.objects as restrictive
 for update to authenticated
 using(bucket_id<>'activity-attachments' or dydem_private.storage_project_writable(name))
 with check(bucket_id<>'activity-attachments' or dydem_private.storage_project_writable(name));

create function dydem_private.project_delete_preview(pid uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.projects%rowtype;ids bigint[];
begin
 if auth.uid() is null or not public.is_dydem_admin() then raise exception 'Solo el Administrador puede eliminar proyectos' using errcode='42501';end if;
 select * into p from public.projects where id=pid;
 if not found then raise exception 'Proyecto no disponible';end if;
 select coalesce(array_agg(id),array[]::bigint[]) into ids from public.activities where project_id=pid;
 return jsonb_build_object('project_id',pid,'name',p.name,'deleting',p.deletion_started_at is not null,
  'activities',cardinality(ids),
  'comments',(select count(*) from public.activity_comments where project_id=pid or activity_id=any(ids)),
  'history',(select count(*) from public.activity_history where activity_id=any(ids)),
  'files',(select count(*) from storage.objects where bucket_id='activity-attachments' and starts_with(name,pid::text||'/')),
  'external_links',(select count(*) from public.dydem_critical_config where not activity_id=any(ids) and predecessors && ids));
end $$;

create function dydem_private.begin_project_delete(pid uuid,p_expected_name text,p_confirmed boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.projects%rowtype;
begin
 if auth.uid() is null or not public.is_dydem_admin() then raise exception 'Solo el Administrador puede eliminar proyectos' using errcode='42501';end if;
 if p_confirmed is distinct from true then raise exception 'Confirma la eliminación del proyecto';end if;
 select * into p from public.projects where id=pid for update;
 if not found then return jsonb_build_object('ok',true,'done',true,'project_id',pid);end if;
 if p.name is distinct from p_expected_name then raise exception 'El proyecto cambió. Revisa su nombre y vuelve a confirmar.';end if;
 if p.deletion_started_at is null then
  update public.projects set deletion_started_at=now(),deletion_token=gen_random_uuid() where id=pid returning * into p;
 end if;
 return jsonb_build_object('ok',true,'done',false,'project_id',pid,'token',p.deletion_token);
end $$;

create function dydem_private.project_delete_step(pid uuid,p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.projects%rowtype;paths jsonb;ids bigint[];
begin
 -- Same lock as the cross-project dependency editor.
 perform pg_advisory_xact_lock(7112026,42);
 select * into p from public.projects where id=pid for update;
 if not found then return jsonb_build_object('ok',true,'done',true,'project_id',pid);end if;
 if p.deletion_started_at is null or p_token is null or p.deletion_token is distinct from p_token then
  raise exception 'La eliminación no está confirmada' using errcode='42501';
 end if;
 select jsonb_agg(name order by name) into paths from (
  select name from storage.objects where bucket_id='activity-attachments' and starts_with(name,pid::text||'/') order by name limit 1000
 ) files;
 if paths is not null then return jsonb_build_object('ok',true,'done',false,'paths',paths);end if;

 select coalesce(array_agg(id),array[]::bigint[]) into ids from public.activities where project_id=pid;
 update public.dydem_critical_config c set predecessors=array(
   select dep from unnest(c.predecessors) dep where not dep=any(ids)),updated_at=now()
  where not activity_id=any(ids) and predecessors && ids;
 delete from public.activity_history where activity_id=any(ids);
 delete from public.activity_comments where project_id=pid or activity_id=any(ids);
 delete from public.activity_upload_intents where project_id=pid or activity_id=any(ids);
 delete from public.proposal_upload_intents where project_id=pid or activity_id=any(ids);
 delete from public.dydem_critical_config where activity_id=any(ids);
 delete from public.dydem_project_members where project_id=pid;
 delete from public.activities where project_id=pid;
 delete from public.annex_counters where starts_with(week_code,pid::text||':')
  or (pid='00000000-0000-4000-8000-00000000d1de'::uuid and week_code ~ '^[0-9]{4}-S[0-9]{2}$');
 delete from public.projects where id=pid;
 return jsonb_build_object('ok',true,'done',true,'project_id',pid,'activities',cardinality(ids));
end $$;

-- Exposed wrappers are invokers; privilege elevation stays outside the API schema.
create function public.dydem_project_delete_preview(pid uuid)
returns jsonb language sql security invoker set search_path='' as $$select dydem_private.project_delete_preview(pid)$$;
create function public.dydem_begin_project_delete(pid uuid,p_expected_name text,p_confirmed boolean)
returns jsonb language sql security invoker set search_path='' as $$select dydem_private.begin_project_delete(pid,p_expected_name,p_confirmed)$$;
create function public.dydem_project_delete_step(pid uuid,p_token uuid)
returns jsonb language sql security invoker set search_path='' as $$select dydem_private.project_delete_step(pid,p_token)$$;

revoke all on all functions in schema dydem_private from public,anon,authenticated;
grant execute on function dydem_private.storage_project_writable(text),dydem_private.project_delete_preview(uuid),dydem_private.begin_project_delete(uuid,text,boolean) to authenticated;
grant execute on function dydem_private.project_delete_step(uuid,uuid) to service_role;
revoke all on function public.dydem_project_delete_preview(uuid),public.dydem_begin_project_delete(uuid,text,boolean),public.dydem_project_delete_step(uuid,uuid) from public,anon,authenticated;
grant execute on function public.dydem_project_delete_preview(uuid),public.dydem_begin_project_delete(uuid,text,boolean) to authenticated;
grant execute on function public.dydem_project_delete_step(uuid,uuid) to service_role;
