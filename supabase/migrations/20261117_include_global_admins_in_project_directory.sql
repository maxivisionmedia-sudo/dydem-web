CREATE OR REPLACE FUNCTION public.list_dydem_responsibles()
 RETURNS TABLE(id uuid, display_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select p.id,
  coalesce(nullif(btrim(p.display_name),''),split_part(p.email,'@',1))::text
 from public.profiles p
 where public.is_active_user()
  and (public.is_dydem_admin() or p.role='admin' or p.id=auth.uid() or exists(select 1 from public.dydem_project_members a join public.dydem_project_members b on b.project_id=a.project_id and b.user_id=p.id where a.user_id=auth.uid()))
  and (p.active or exists(
   select 1 from public.activities a
   where a.deleted_at is null and
    (coalesce(a.data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(p.id::text)
      or coalesce(a.data->'responsibles'->'authorization','[]'::jsonb) @> jsonb_build_array(p.id::text)
      or coalesce(a.data->'responsibles'->'verification','[]'::jsonb) @> jsonb_build_array(p.id::text))
  ))
 union all
 select old.id,old.display_name from public.dydem_departed_users old
 where public.is_active_user()
   and exists(
    select 1 from public.activities a where a.deleted_at is null and public.dydem_has_project_access(a.project_id)
      and (coalesce(a.data->'responsibles'->'review','[]'::jsonb) @> jsonb_build_array(old.id::text)
       or coalesce(a.data->'responsibles'->'authorization','[]'::jsonb) @> jsonb_build_array(old.id::text)
       or coalesce(a.data->'responsibles'->'verification','[]'::jsonb) @> jsonb_build_array(old.id::text))
   )
 order by 2,1;
$function$;