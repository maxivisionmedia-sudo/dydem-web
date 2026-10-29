-- Permitir la eliminación definitiva de comentarios solo a administradores activos.
-- Mantener SELECT/INSERT para administradores y visualizadores.
-- RLS se aplica usando perfiles activos, no claims editables del navegador.
drop policy if exists dydem_comments_admin_delete on public.activity_comments;

create policy dydem_comments_admin_delete on public.activity_comments
for delete to authenticated
using (
  public.is_dydem_admin()
  and project_id = '00000000-0000-4000-8000-00000000d1de'
  and exists (
    select 1 from public.activities a
    where a.id = activity_id
      and a.project_id = activity_comments.project_id
      and a.deleted_at is null
  )
);

-- El GRANT permite intentar la operación, pero la política RLS solo
-- autoriza filas cuando quien solicita la eliminación es administrador.
grant delete on public.activity_comments to authenticated;
