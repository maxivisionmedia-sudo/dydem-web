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

## Lista de actividades

Debajo del cronograma, los filtros de la lista permiten consultar todas las actividades, las que requieren la aprobación del usuario, la obra atrasada o el cierre pendiente. La búsqueda acepta nombres, números y anexos, con o sin acentos. Los contadores de cada filtro se calculan sobre los resultados de la búsqueda.

- **Obra atrasada:** fin previsto anterior a hoy en Ciudad de México, sin terminar la obra ni finalizar la actividad.
- **Cierre pendiente:** avance físico del 100 % o etapa de obra completada, con finalización todavía pendiente.
- **Requieren mi aprobación:** responsables asignados que aún no confirman una etapa disponible. No incluye aprobaciones futuras ni concede permisos adicionales.
- **Abrir etapa:** expande la tarjeta y muestra la etapa correspondiente. La confirmación se realiza mediante el control existente dentro de esa etapa.

Los filtros afectan únicamente a la lista. El cronograma y los reportes conservan su alcance. Al navegar desde el cronograma hacia una actividad se limpian los filtros para hacerla visible. Cambiar de proyecto o cerrar sesión reinicia los filtros.

Pruebas de lógica sin dependencias: `node --test tests/*.test.cjs`. La comprobación visual debe cubrir las tres vistas de usuario, el acceso directo a etapas, los filtros y la navegación desde el cronograma.

## Leyenda del Gantt

El pie del Gantt explica la duración inclusiva en días naturales, la holgura total, las actividades críticas, las exclusiones y el alcance global del fin CPM. El apartado desplegable «Cómo se calcula la ruta crítica» describe los recorridos hacia adelante y atrás con un ejemplo. El PDF repite una leyenda resumida por hoja y admite hasta 16 actividades por página para reservarle espacio, manteniendo cuatro semanas horizontales.

El cálculo permanece basado en las fechas previstas y las dependencias incluidas: no utiliza el porcentaje ejecutado para descontar duración, no nivela recursos y no aplica una fecha límite contractual. El inicio previsto funciona como restricción de no comenzar antes de esa fecha. `tests/critical-cpm.test.cjs` verifica los ejemplos y estos límites contra el motor utilizado por la aplicación.

## Eliminar un proyecto

Solo el administrador ve **Eliminar proyecto**. El primer clic consulta un resumen; el segundo botón, **Sí, eliminar todo**, confirma el nombre y el alcance. Cancelar no modifica datos. La eliminación incluye actividades activas y previamente ocultadas, notas, dudas, historial, archivos de Revisión/Evidencia, cargas pendientes, membresías, contadores de anexos y configuración del Gantt. Las cuentas de usuario se conservan. Se retiran las dependencias de otras actividades hacia las eliminadas.

La función `manage-projects` comprueba la identidad y el rol, bloquea nuevas escrituras y elimina los archivos mediante la API de Storage en lotes. Solo después de comprobar que no quedan objetos bajo el prefijo exacto del proyecto se purgan los registros en una transacción. Si se interrumpe, el proyecto muestra **Reintentar eliminación**. El último proyecto también puede eliminarse: **Nuevo proyecto** sigue accesible. Las instantáneas de versiones guardadas por separado no se reescriben.

Desplegar primero la migración `project_hard_delete_with_confirmation` y la función `manage-projects`, y después el cliente web. Las nuevas funciones privilegiadas están en `dydem_private`; el paso de purga solo concede ejecución al rol del servidor. Las pruebas JavaScript cubren confirmación, permisos y errores de Storage; `tests/project-delete.sql` comprueba el borrado con datos sintéticos dentro de una transacción que siempre se revierte. No simula la eliminación de binarios reales.

## Punto de restauración previo a las mejoras de experiencia

**v0.4** conserva el código anterior a estos filtros en la rama `versiones/v0.4`, commit `07381c949be3dcb1e62527b1f798654443a984e7`. La instantánea privada de datos y configuración está identificada como `0.4` en `dydem_archives.releases`. Incluye el sistema multiproyecto, membresías y Gantt con PDF. No duplica los binarios de los adjuntos ni las credenciales de Auth. Para restaurar, distinguir entre recuperar el código y reemplazar también los datos posteriores.
