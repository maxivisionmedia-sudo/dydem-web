-- Migration: DYDEM comments (already applied to the linked Supabase project).
-- Re-run only on a new installation or through migration tooling; does not modify activities.
create table if not exists public.activity_comments (
 id bigint generated always as identity primary key,
 project_id uuid not null default '00000000-0000-4000-8000-00000000d1de' references public.projects(id),
 activity_id bigint not null references public.activities(id) on delete cascade,
 author_id uuid not null default auth.uid() references auth.users(id),
 author_name text not null default '',
 body text not null check (char_length(btrim(body)) between 1 and 2000),
 created_at timestamptz not null default now()
);
create index if not exists dydem_comments_activity_time_idx on public.activity_comments(activity_id,created_at,id);
create index if not exists dydem_comments_project_time_idx on public.activity_comments(project_id,created_at,id);
alter table public.activity_comments enable row level security;

create or replace function public.dydem_prepare_comment()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_author text;
begin
 if auth.uid() is null or not public.is_active_user() then
  raise exception 'Se requiere una cuenta activa de DYDEM' using errcode='42501';
 end if;
 if new.body is null or char_length(btrim(new.body)) not between 1 and 2000 then
  raise exception 'El comentario debe contener entre 1 y 2000 caracteres';
 end if;
 if not exists(select 1 from public.activities a where a.id=new.activity_id and a.project_id='00000000-0000-4000-8000-00000000d1de' and a.deleted_at is null) then
  raise exception 'La actividad ya no está disponible para comentarios';
 end if;
 select coalesce(nullif(p.display_name,''),nullif(p.email,''),'Usuario') into v_author
 from public.profiles p where p.id=auth.uid() and p.active;
 if v_author is null then raise exception 'No se encontró el usuario activo' using errcode='42501'; end if;
 new.project_id:='00000000-0000-4000-8000-00000000d1de';
 new.author_id:=auth.uid();
 new.author_name:=v_author;
 new.body:=btrim(new.body);
 new.created_at:=now();
 return new;
end $$;
revoke all on function public.dydem_prepare_comment() from public,anon,authenticated;
drop trigger if exists dydem_prepare_comment_insert on public.activity_comments;
create trigger dydem_prepare_comment_insert before insert on public.activity_comments
for each row execute function public.dydem_prepare_comment();

drop policy if exists dydem_comments_read on public.activity_comments;
create policy dydem_comments_read on public.activity_comments
for select to authenticated using(public.is_active_user() and project_id='00000000-0000-4000-8000-00000000d1de'
 and exists(select 1 from public.activities a where a.id=activity_id and a.deleted_at is null));
drop policy if exists dydem_comments_post on public.activity_comments;
create policy dydem_comments_post on public.activity_comments for insert to authenticated
with check(public.is_active_user() and author_id=auth.uid() and project_id='00000000-0000-4000-8000-00000000d1de'
 and exists(select 1 from public.activities a where a.id=activity_id and a.deleted_at is null));
revoke all on public.activity_comments from anon,authenticated;
grant select,insert on public.activity_comments to authenticated;
do $realtime$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='activity_comments') then
  alter publication supabase_realtime add table public.activity_comments;
 end if;
end $realtime$;
