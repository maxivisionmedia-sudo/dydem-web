
-- DYDEM: edición de comentarios granular, con lectura permitida para cualquier usuario activo.
-- Las cuentas personalizadas actuales empiezan con publicar comentarios deshabilitado.
alter table public.profiles drop constraint if exists dydem_custom_permission_shape;
alter table public.profiles alter column permissions
 set default '{"steps":[false,false,false,false,false,false,false],"add":false,"delete":false,"comment":false}'::jsonb;
update public.profiles
set permissions=jsonb_set(permissions,'{comment}','false'::jsonb,true)
where not(permissions ? 'comment');
alter table public.profiles add constraint dydem_custom_permission_shape check (
 jsonb_typeof(permissions)='object'
 and jsonb_typeof(permissions->'steps')='array'
 and jsonb_array_length(permissions->'steps')=7
 and jsonb_typeof(permissions->'add')='boolean'
 and jsonb_typeof(permissions->'delete')='boolean'
 and jsonb_typeof(permissions->'comment')='boolean'
 and jsonb_typeof(permissions->'steps'->0)='boolean'
 and jsonb_typeof(permissions->'steps'->1)='boolean'
 and jsonb_typeof(permissions->'steps'->2)='boolean'
 and jsonb_typeof(permissions->'steps'->3)='boolean'
 and jsonb_typeof(permissions->'steps'->4)='boolean'
 and jsonb_typeof(permissions->'steps'->5)='boolean'
 and jsonb_typeof(permissions->'steps'->6)='boolean'
);
create or replace function public.dydem_can(p_permission text) returns boolean
 language sql stable security definer set search_path=public,pg_temp as $permission$
 select exists(
  select 1 from public.profiles where id=auth.uid() and active
   and (role='admin' or (role='custom' and (
     case
      when p_permission in ('add','delete','comment')
       then permissions->>p_permission='true'
      when p_permission ~ '^step[0-6]$'
       then permissions->'steps'->((right(p_permission,1))::int)='true'::jsonb
      else false
     end
   )))
 )
 $permission$;
revoke all on function public.dydem_can(text) from public,anon;
grant execute on function public.dydem_can(text) to authenticated;
drop policy if exists dydem_comments_post on public.activity_comments;
create policy dydem_comments_post on public.activity_comments
 for insert to authenticated
 with check(
  public.dydem_can('comment')
  and author_id=auth.uid()
  and project_id='00000000-0000-4000-8000-00000000d1de'
  and exists(select 1 from public.activities a
             where a.id=activity_id and a.project_id=activity_comments.project_id
             and a.deleted_at is null)
 );
-- La política de lectura no cambia: todo usuario activo puede consultar comentarios.
