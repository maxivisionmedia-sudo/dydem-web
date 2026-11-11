-- Detect review-owned Storage paths without relying on caller's
-- RLS visibility of a different uploader's intent. This closes the
-- doc_delete bypass after Review is finished.
create or replace function public.dydem_is_review_storage_path(p_path text)
returns boolean language sql stable security definer
set search_path=public,pg_temp as $f$
 select exists(select 1 from public.proposal_upload_intents
  where storage_path=p_path);
$f$;
revoke all on function public.dydem_is_review_storage_path(text) from public,anon;
grant execute on function public.dydem_is_review_storage_path(text) to authenticated;

drop policy if exists dydem_attachments_upload on storage.objects;
create policy dydem_attachments_upload on storage.objects
 for insert to authenticated
 with check (
  bucket_id='activity-attachments'
  and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
  and (
   (public.dydem_can('doc_add') and not public.dydem_is_review_storage_path(name))
   or public.dydem_review_storage_path(name,'add')
  )
 );

drop policy if exists dydem_attachments_delete on storage.objects;
create policy dydem_attachments_delete on storage.objects
 for delete to authenticated
 using (
  bucket_id='activity-attachments'
  and split_part(name,'/',1)='00000000-0000-4000-8000-00000000d1de'
  and (
   (public.dydem_can('doc_delete') and not public.dydem_is_review_storage_path(name))
   or public.dydem_review_storage_path(name,'delete')
  )
 );
