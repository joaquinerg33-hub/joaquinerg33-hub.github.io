-- ============================================================================
-- Paso 2: date de alta como administrador y crea tus primeras obras.
-- ============================================================================
-- 1. Antes de correr esto, inicia sesión al menos UNA vez en erp/index.html con
--    tu correo (así se crea tu fila en "profiles" automáticamente).
-- 2. Reemplaza el correo de abajo por el tuyo y ejecuta este archivo en el SQL Editor.
-- 3. Puedes volver a correr este archivo cuando quieras para agregar más obras
--    (las que ya existen, por su "codigo" único, no se duplican).

update public.profiles
set role = 'admin'
where email = 'joaquinerg33@gmail.com';

insert into public.obras (codigo, nombre) values
  ('100', 'Obra 100 — (reemplaza por el nombre real)'),
  ('209', 'Obra 209 — (reemplaza por el nombre real)')
on conflict (codigo) do nothing;

-- Para asignar un residente a una obra (una vez que ya inició sesión y tiene su
-- perfil creado), usa la pantalla "Usuarios" dentro de la app (rol admin/logística),
-- o corre algo como esto reemplazando los correos/códigos:
--
-- insert into public.obra_usuarios (obra_id, user_id)
-- select o.id, p.id
-- from public.obras o, public.profiles p
-- where o.codigo = '100' and p.email = 'residente@empresa.com'
-- on conflict do nothing;
