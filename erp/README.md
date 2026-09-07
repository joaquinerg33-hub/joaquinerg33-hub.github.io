# ERP — Módulo Logística: Solicitudes de Materiales

Primer módulo de lo que puede crecer a un ERP completo de la empresa (más
adelante: Cantera/Proveedores, Finanzas, Recursos Humanos...). Vive en
`erp/index.html`, es una página nueva y separada de `index.html` (Cantera),
pero **usa el mismo proyecto de Supabase** — así los correos corporativos que
ya usan para Cantera sirven también para iniciar sesión aquí.

## Qué resuelve

- Solicitudes de materiales en línea (no más Word/Excel/correo suelto).
- Flujo con roles: **Residente** sube → **Gerente de Operaciones** aprueba o
  rechaza → **Logística** recién ve las solicitudes ya aprobadas.
- Una vez aprobada una cantidad, **nadie puede editarla directamente**: si el
  residente se equivocó, tiene que "Solicitar cambio" con un motivo, y el
  gerente lo aprueba o rechaza. Todo queda en la línea de tiempo con el
  antes/después y quién lo pidió.
- Notificaciones dentro de la app (campanita 🔔) cuando: te llega una
  solicitud para revisar, te aprueban/rechazan la tuya, o alguien pide un
  cambio de cantidad.
- Todo se actualiza solo (tiempo real) sin recargar la página.

## Puesta en marcha (una sola vez)

1. **Base de datos**: entra a tu proyecto de Supabase → *SQL Editor* → pega y
   ejecuta **`sql/001_schema.sql`** completo. Crea las tablas, los permisos
   (RLS) y toda la lógica del flujo.
2. Abre `erp/index.html` en el navegador (o publícalo en GitHub Pages) e
   inicia sesión con tu correo (el mismo que usas en Cantera). Esto crea tu
   perfil automáticamente con rol "Residente".
3. Vuelve al SQL Editor, abre **`sql/002_seed_admin.sql`**, reemplaza el
   correo por el tuyo y ejecútalo. Esto te asciende a **Administrador** y
   deja dos obras de ejemplo (edítalas con los nombres/códigos reales, o
   agrega las que falten con el mismo `insert into obras...`).
4. Vuelve a entrar a la app: ya deberías ver el rol "Administrador" y el
   módulo **Usuarios y roles** en la barra lateral.

## Dar de alta a tu equipo

Como todavía no está activado el inicio de sesión con Microsoft (se puede
sumar más adelante), cada persona necesita una cuenta de correo+contraseña en
Supabase:

1. Panel de Supabase → **Authentication → Users → Invite user** (o *Add
   user*), con su correo corporativo.
2. Esa persona inicia sesión en `erp/index.html` (con la contraseña que le
   llegue, o usando "Olvidé mi contraseña" para fijar una).
3. Se le crea su perfil automáticamente con rol **Residente**.
4. Tú, desde **Usuarios y roles**, le cambias el rol si corresponde
   (Gerente de Operaciones, Logística, etc.) y — si es residente — marcas a
   qué obra(s) queda asignado.

## Roles

| Rol | Puede |
|---|---|
| **Residente** | Crear solicitudes para sus obras, editarlas mientras están en borrador o si se las rechazaron, comentar, y pedir cambios de cantidad sobre una ya aprobada. |
| **Gerente de Operaciones** | Ver todas las solicitudes enviadas, aprobar/rechazar (puede ajustar cantidades al aprobar), y resolver los pedidos de cambio. |
| **Logística** | Solo ve solicitudes desde que están **aprobadas** en adelante; las marca en proceso / atendida / cerrada. |
| **Lectura** | Solo consulta, desde "aprobada" en adelante. |
| **Administrador** | Todo lo anterior + gestión de usuarios/roles/obras. |

## Cómo se protege todo (por si migra a otras manos)

La seguridad no depende de la interfaz: vive en la base de datos.

- **RLS (Row Level Security)** en cada tabla decide qué fila puede ver cada
  quien según su rol — aunque alguien abra las herramientas del navegador,
  no puede leer ni escribir lo que su rol no permite.
- Los cambios de estado sensibles (enviar, aprobar, rechazar, aprobar un
  cambio de cantidad, marcar como atendida) **no se hacen con un simple
  `update`** desde el navegador: pasan por funciones de base de datos
  (`enviar_solicitud`, `aprobar_solicitud`, etc.) que primero verifican el
  rol y el estado, y dejan registro en la línea de tiempo. Así nadie puede
  saltarse el flujo aunque manipule la app.
- Un disparador (`trg_bloquear_items`) impide editar `cantidad_aprobada`
  directamente por fuera de esas funciones, sin importar el rol.

## Siguientes módulos (cuando quieras sumarlos)

La barra lateral ya deja espacio para "Cantera", "Finanzas" y "Recursos
Humanos" (aparecen como "Próximamente"). Cada uno puede vivir en su propia
carpeta/página (igual que esta), reutilizando el mismo login y la misma
tabla `profiles` — solo se le agregan sus propias tablas y políticas RLS.

## Notificaciones por correo (pendiente, cuando quieras activarlas)

Por ahora las notificaciones son solo dentro de la app. El día que quieras
que también lleguen por correo, se puede conectar un servicio como Resend
(tiene plan gratuito) mediante una Edge Function de Supabase que se dispare
cuando se inserta una fila en `notificaciones` — no requiere cambiar nada de
lo ya construido, solo se suma.
