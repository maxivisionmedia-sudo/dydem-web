# DYDEM — Control de Obra

Aplicación web privada para 1–5 usuarios, con interfaz alojada en GitHub Pages y datos protegidos en Supabase.

## Acceso

Tras habilitar GitHub Pages desde Settings → Pages → Deploy from a branch → main → /(root), el acceso será https://maxivisionmedia-sudo.github.io/dydem-web/.

## Configuración

- Supabase Project Ref: `tzcmmpdltmjqnwcshozw`.
- `config.js` contiene únicamente una clave pública de navegador. Nunca colocar claves secretas en GitHub.
- En Supabase → Authentication → URL Configuration, establecer Site URL y Redirect URLs con `https://maxivisionmedia-sudo.github.io/dydem-web/`.
- La Edge Function `manage-users` valida el origen de GitHub Pages para las invitaciones.
- Para migrar actividades existentes: exportar el respaldo JSON de la versión local y usar la función Importar respaldo en línea; los archivos adjuntos se cargan por separado.

## Seguridad

El repositorio es público, pero las actividades requieren inicio de sesión y están protegidas por políticas RLS. No utilizar la versión local en paralelo después de migrar.
