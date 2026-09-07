-- ============================================================================
-- ERP — Módulo Logística: Solicitudes de Materiales
-- ============================================================================
-- Cómo usar este archivo:
--   1. Entra a tu proyecto de Supabase → SQL Editor.
--   2. Pega TODO este archivo y ejecútalo una sola vez (botón "Run").
--   3. Repite lo mismo con 002_seed_admin.sql (edítalo primero con tu correo).
-- Es seguro volver a correr este archivo si algo falla a la mitad: los
-- "create ... if not exists" y "drop ... if exists" evitan duplicados.
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. PERFILES (un perfil por cada usuario que inicia sesión)
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  role text not null default 'residente'
    check (role in ('admin','logistica','gerente_operaciones','residente','lectura')),
  activo boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table public.profiles is 'Un usuario = una cuenta de Supabase Auth = una fila aquí con su rol dentro del ERP.';
comment on column public.profiles.role is 'admin: control total. logistica: jefe de logística (solo ve solicitudes ya aprobadas). gerente_operaciones: aprueba/rechaza. residente: crea solicitudes de su(s) obra(s). lectura: solo consulta.';

-- Cuando alguien inicia sesión por primera vez (cuenta creada por invitación desde
-- el dashboard de Supabase), se le crea automáticamente su perfil con rol "residente".
-- Un admin lo asciende después desde la pantalla de Usuarios.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Funciones de ayuda para las políticas de seguridad (RLS)
create or replace function public.mi_rol()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;
create or replace function public.es_admin() returns boolean language sql stable as $$ select public.mi_rol() = 'admin' $$;
create or replace function public.es_logistica() returns boolean language sql stable as $$ select public.mi_rol() in ('admin','logistica') $$;
create or replace function public.es_gerente() returns boolean language sql stable as $$ select public.mi_rol() in ('admin','gerente_operaciones') $$;
create or replace function public.es_residente() returns boolean language sql stable as $$ select public.mi_rol() in ('admin','residente') $$;

-- ----------------------------------------------------------------------------
-- 2. OBRAS (centros de costo)
-- ----------------------------------------------------------------------------
create table if not exists public.obras (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  nombre text not null,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.obra_usuarios (
  obra_id uuid not null references public.obras(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (obra_id, user_id)
);
comment on table public.obra_usuarios is 'A qué obra(s) está asignado cada residente. Gerente/logística/admin ven todas las obras sin necesidad de estar aquí.';

-- ----------------------------------------------------------------------------
-- 3. SOLICITUDES + ITEMS
-- ----------------------------------------------------------------------------
create table if not exists public.solicitudes (
  id uuid primary key default gen_random_uuid(),
  numero integer not null,
  obra_id uuid not null references public.obras(id),
  solicitante_id uuid not null references public.profiles(id),
  tipo text not null default 'materiales',
  estado text not null default 'borrador'
    check (estado in ('borrador','enviada','rechazada','aprobada','en_proceso','atendida','cerrada')),
  fecha_requerida date,
  motivo_rechazo text,
  aprobada_por uuid references public.profiles(id),
  aprobada_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (obra_id, numero)
);

create or replace function public.set_numero_solicitud()
returns trigger language plpgsql as $$
begin
  if new.numero is null then
    select coalesce(max(numero), 0) + 1 into new.numero
    from public.solicitudes where obra_id = new.obra_id;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_numero_solicitud on public.solicitudes;
create trigger trg_numero_solicitud
  before insert on public.solicitudes
  for each row execute function public.set_numero_solicitud();

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
drop trigger if exists trg_solicitudes_updated_at on public.solicitudes;
create trigger trg_solicitudes_updated_at
  before update on public.solicitudes
  for each row execute function public.set_updated_at();

create table if not exists public.solicitud_items (
  id uuid primary key default gen_random_uuid(),
  solicitud_id uuid not null references public.solicitudes(id) on delete cascade,
  item_codigo text,
  descripcion text not null,
  unidad text not null default 'und',
  categoria text,
  cantidad_solicitada numeric not null check (cantidad_solicitada > 0),
  cantidad_aprobada numeric,
  estado_item text not null default 'pendiente'
    check (estado_item in ('pendiente','atendido','rechazado')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists trg_items_updated_at on public.solicitud_items;
create trigger trg_items_updated_at
  before update on public.solicitud_items
  for each row execute function public.set_updated_at();

-- Candado: una vez que la solicitud dejó de ser 'borrador'/'rechazada', nadie puede
-- tocar cantidad_aprobada directamente desde el cliente — solo las funciones RPC
-- de este archivo (aprobar_solicitud / resolver_cambio) lo hacen, vía SECURITY DEFINER.
create or replace function public.bloquear_edicion_directa_items()
returns trigger language plpgsql as $$
declare v_estado text; v_via_rpc boolean;
begin
  select estado into v_estado from public.solicitudes where id = new.solicitud_id;
  v_via_rpc := coalesce(current_setting('erp.via_rpc', true), 'false') = 'true';
  if v_estado not in ('borrador','rechazada') and not v_via_rpc then
    raise exception 'Esta solicitud ya fue enviada/aprobada: los ítems no se pueden editar directamente. Usa "Solicitar cambio".';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_bloquear_items on public.solicitud_items;
create trigger trg_bloquear_items
  before update on public.solicitud_items
  for each row execute function public.bloquear_edicion_directa_items();

-- ----------------------------------------------------------------------------
-- 4. CAMBIOS SOLICITADOS (pedir modificar una cantidad ya aprobada)
-- ----------------------------------------------------------------------------
create table if not exists public.cambios_solicitados (
  id uuid primary key default gen_random_uuid(),
  solicitud_id uuid not null references public.solicitudes(id) on delete cascade,
  item_id uuid not null references public.solicitud_items(id) on delete cascade,
  cantidad_actual numeric not null,
  cantidad_propuesta numeric not null,
  motivo text not null,
  solicitado_por uuid not null references public.profiles(id),
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobado','rechazado')),
  resuelto_por uuid references public.profiles(id),
  resuelto_comentario text,
  resuelto_at timestamptz,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 5. LÍNEA DE TIEMPO (eventos + comentarios en un solo lugar)
-- ----------------------------------------------------------------------------
create table if not exists public.eventos (
  id uuid primary key default gen_random_uuid(),
  solicitud_id uuid not null references public.solicitudes(id) on delete cascade,
  usuario_id uuid references public.profiles(id),
  tipo text not null,
  mensaje text,
  detalle jsonb,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 6. NOTIFICACIONES (bandeja dentro de la app)
-- ----------------------------------------------------------------------------
create table if not exists public.notificaciones (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  solicitud_id uuid references public.solicitudes(id) on delete cascade,
  tipo text not null,
  mensaje text not null,
  leida boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_notificaciones_user on public.notificaciones(user_id, leida, created_at desc);

create or replace function public.notificar(p_user_id uuid, p_solicitud_id uuid, p_tipo text, p_mensaje text)
returns void language sql as $$
  insert into public.notificaciones(user_id, solicitud_id, tipo, mensaje)
  values (p_user_id, p_solicitud_id, p_tipo, p_mensaje);
$$;

create or replace function public.notificar_rol(p_roles text[], p_solicitud_id uuid, p_tipo text, p_mensaje text)
returns void language sql as $$
  insert into public.notificaciones(user_id, solicitud_id, tipo, mensaje)
  select id, p_solicitud_id, p_tipo, p_mensaje from public.profiles
  where role = any(p_roles) and activo;
$$;

-- ============================================================================
-- SEGURIDAD A NIVEL DE FILA (RLS)
-- ============================================================================
alter table public.profiles enable row level security;
alter table public.obras enable row level security;
alter table public.obra_usuarios enable row level security;
alter table public.solicitudes enable row level security;
alter table public.solicitud_items enable row level security;
alter table public.cambios_solicitados enable row level security;
alter table public.eventos enable row level security;
alter table public.notificaciones enable row level security;

-- profiles: todos ven la lista básica (para mostrar nombres); solo el propio
-- usuario o un admin puede actualizar, y el rol solo lo cambia un admin.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (true);
drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_update_admin on public.profiles for update using (public.es_admin());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and role = (select role from public.profiles where id = auth.uid()));

-- obras: todos los autenticados pueden ver; solo admin/logística administran.
drop policy if exists obras_select on public.obras;
create policy obras_select on public.obras for select using (auth.uid() is not null);
drop policy if exists obras_write on public.obras;
create policy obras_write on public.obras for all using (public.es_logistica()) with check (public.es_logistica());

-- obra_usuarios: el propio usuario ve sus asignaciones; admin/logística ven y editan todo.
drop policy if exists obra_usuarios_select on public.obra_usuarios;
create policy obra_usuarios_select on public.obra_usuarios for select
  using (user_id = auth.uid() or public.es_logistica() or public.es_gerente());
drop policy if exists obra_usuarios_write on public.obra_usuarios;
create policy obra_usuarios_write on public.obra_usuarios for all
  using (public.es_logistica()) with check (public.es_logistica());

-- solicitudes:
--  · residente: ve las suyas siempre.
--  · gerente: ve todas salvo borradores ajenos.
--  · logística/admin: ve desde 'aprobada' en adelante (admin además ve todo).
drop policy if exists solicitudes_select on public.solicitudes;
create policy solicitudes_select on public.solicitudes for select using (
  public.es_admin()
  or solicitante_id = auth.uid()
  or (public.es_gerente() and estado <> 'borrador')
  or (public.mi_rol() = 'logistica' and estado in ('aprobada','en_proceso','atendida','cerrada'))
  or (public.mi_rol() = 'lectura' and estado in ('aprobada','en_proceso','atendida','cerrada'))
);
drop policy if exists solicitudes_insert on public.solicitudes;
create policy solicitudes_insert on public.solicitudes for insert with check (
  solicitante_id = auth.uid() and estado = 'borrador'
  and (public.es_admin() or exists (
    select 1 from public.obra_usuarios ou where ou.obra_id = obra_id and ou.user_id = auth.uid()
  ))
);
-- Update directo desde el cliente: SOLO el dueño y SOLO mientras está en
-- borrador/rechazada (para editar cabecera antes de reenviar). Los cambios de
-- estado (enviar/aprobar/rechazar/...) van siempre por las funciones RPC de abajo.
drop policy if exists solicitudes_update_owner on public.solicitudes;
create policy solicitudes_update_owner on public.solicitudes for update
  using (solicitante_id = auth.uid() and estado in ('borrador','rechazada'))
  with check (solicitante_id = auth.uid() and estado in ('borrador','rechazada'));
drop policy if exists solicitudes_delete_owner on public.solicitudes;
create policy solicitudes_delete_owner on public.solicitudes for delete
  using (solicitante_id = auth.uid() and estado = 'borrador');

-- solicitud_items: visibles si la solicitud padre es visible; editables por el
-- dueño solo mientras la solicitud está en borrador/rechazada (el trigger de
-- arriba bloquea cualquier otro caso, incluida cantidad_aprobada).
drop policy if exists items_select on public.solicitud_items;
create policy items_select on public.solicitud_items for select using (
  exists (select 1 from public.solicitudes s where s.id = solicitud_id)
);
drop policy if exists items_write_owner on public.solicitud_items;
create policy items_write_owner on public.solicitud_items for all using (
  exists (select 1 from public.solicitudes s where s.id = solicitud_id
          and s.solicitante_id = auth.uid() and s.estado in ('borrador','rechazada'))
) with check (
  exists (select 1 from public.solicitudes s where s.id = solicitud_id
          and s.solicitante_id = auth.uid() and s.estado in ('borrador','rechazada'))
);

-- cambios_solicitados: visibles si la solicitud es visible; solo se crean vía RPC.
drop policy if exists cambios_select on public.cambios_solicitados;
create policy cambios_select on public.cambios_solicitados for select using (
  exists (select 1 from public.solicitudes s where s.id = solicitud_id)
);

-- eventos: visibles si la solicitud es visible; se insertan vía RPC (comentar_solicitud incluido).
drop policy if exists eventos_select on public.eventos;
create policy eventos_select on public.eventos for select using (
  exists (select 1 from public.solicitudes s where s.id = solicitud_id)
);

-- notificaciones: cada quien ve y marca solo las suyas.
drop policy if exists notificaciones_select on public.notificaciones;
create policy notificaciones_select on public.notificaciones for select using (user_id = auth.uid());
drop policy if exists notificaciones_update_own on public.notificaciones;
create policy notificaciones_update_own on public.notificaciones for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- FUNCIONES RPC — toda la lógica de negocio sensible vive aquí (SECURITY DEFINER),
-- para que ningún usuario pueda saltarse el flujo escribiendo directo a las tablas.
-- ============================================================================

create or replace function public.enviar_solicitud(p_solicitud_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_sol record;
begin
  select * into v_sol from solicitudes where id = p_solicitud_id;
  if v_sol is null then raise exception 'Solicitud no encontrada'; end if;
  if v_sol.solicitante_id <> auth.uid() and not es_admin() then raise exception 'No autorizado'; end if;
  if v_sol.estado not in ('borrador','rechazada') then raise exception 'Solo se puede enviar desde borrador o rechazada'; end if;
  if not exists (select 1 from solicitud_items where solicitud_id = p_solicitud_id) then
    raise exception 'La solicitud no tiene ítems';
  end if;

  perform set_config('erp.via_rpc', 'true', true);
  update solicitudes set estado = 'enviada', motivo_rechazo = null where id = p_solicitud_id;
  update solicitud_items set cantidad_aprobada = cantidad_solicitada, estado_item = 'pendiente'
    where solicitud_id = p_solicitud_id;

  insert into eventos(solicitud_id, usuario_id, tipo, mensaje)
    values (p_solicitud_id, auth.uid(), 'enviada', 'Solicitud enviada para revisión.');
  perform notificar_rol(array['gerente_operaciones','admin'], p_solicitud_id, 'enviada',
    'Nueva solicitud N°' || v_sol.numero || ' pendiente de tu revisión.');
end;
$$;

create or replace function public.aprobar_solicitud(p_solicitud_id uuid, p_items jsonb default null, p_comentario text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_sol record; v_item jsonb; v_ajustes text := '';
begin
  if not es_gerente() then raise exception 'No autorizado'; end if;
  select * into v_sol from solicitudes where id = p_solicitud_id;
  if v_sol is null then raise exception 'Solicitud no encontrada'; end if;
  if v_sol.estado <> 'enviada' then raise exception 'Solo se puede aprobar una solicitud enviada'; end if;

  perform set_config('erp.via_rpc', 'true', true);
  if p_items is not null then
    for v_item in select * from jsonb_array_elements(p_items) loop
      update solicitud_items
        set cantidad_aprobada = (v_item->>'cantidad_aprobada')::numeric
        where id = (v_item->>'item_id')::uuid and solicitud_id = p_solicitud_id;
    end loop;
  end if;

  update solicitudes set estado = 'aprobada', aprobada_por = auth.uid(), aprobada_at = now()
    where id = p_solicitud_id;

  insert into eventos(solicitud_id, usuario_id, tipo, mensaje, detalle)
    values (p_solicitud_id, auth.uid(), 'aprobada', coalesce(p_comentario, 'Solicitud aprobada.'), p_items);
  perform notificar(v_sol.solicitante_id, p_solicitud_id, 'aprobada',
    'Tu solicitud N°' || v_sol.numero || ' fue aprobada.');
  perform notificar_rol(array['logistica','admin'], p_solicitud_id, 'aprobada',
    'Solicitud N°' || v_sol.numero || ' aprobada y lista para atender.');
end;
$$;

create or replace function public.rechazar_solicitud(p_solicitud_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_sol record;
begin
  if not es_gerente() then raise exception 'No autorizado'; end if;
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'El motivo de rechazo es obligatorio'; end if;
  select * into v_sol from solicitudes where id = p_solicitud_id;
  if v_sol is null then raise exception 'Solicitud no encontrada'; end if;
  if v_sol.estado <> 'enviada' then raise exception 'Solo se puede rechazar una solicitud enviada'; end if;

  perform set_config('erp.via_rpc', 'true', true);
  update solicitudes set estado = 'rechazada', motivo_rechazo = p_motivo where id = p_solicitud_id;

  insert into eventos(solicitud_id, usuario_id, tipo, mensaje)
    values (p_solicitud_id, auth.uid(), 'rechazada', p_motivo);
  perform notificar(v_sol.solicitante_id, p_solicitud_id, 'rechazada',
    'Tu solicitud N°' || v_sol.numero || ' fue rechazada: ' || p_motivo);
end;
$$;

create or replace function public.solicitar_cambio(p_item_id uuid, p_cantidad_propuesta numeric, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_item record; v_sol record;
begin
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'El motivo es obligatorio'; end if;
  select * into v_item from solicitud_items where id = p_item_id;
  if v_item is null then raise exception 'Ítem no encontrado'; end if;
  select * into v_sol from solicitudes where id = v_item.solicitud_id;
  if v_sol.solicitante_id <> auth.uid() and not es_admin() then raise exception 'No autorizado'; end if;
  if v_sol.estado not in ('aprobada','en_proceso') then
    raise exception 'Solo se pueden pedir cambios sobre una solicitud ya aprobada';
  end if;

  insert into cambios_solicitados(solicitud_id, item_id, cantidad_actual, cantidad_propuesta, motivo, solicitado_por)
    values (v_sol.id, p_item_id, v_item.cantidad_aprobada, p_cantidad_propuesta, p_motivo, auth.uid());

  insert into eventos(solicitud_id, usuario_id, tipo, mensaje, detalle)
    values (v_sol.id, auth.uid(), 'cambio_solicitado',
      format('Pidió cambiar "%s" de %s a %s %s. Motivo: %s', v_item.descripcion, v_item.cantidad_aprobada, p_cantidad_propuesta, v_item.unidad, p_motivo),
      jsonb_build_object('item_id', p_item_id, 'de', v_item.cantidad_aprobada, 'a', p_cantidad_propuesta));
  perform notificar_rol(array['gerente_operaciones','admin'], v_sol.id, 'cambio_solicitado',
    'Solicitud N°' || v_sol.numero || ': pidieron cambiar "' || v_item.descripcion || '" de ' || v_item.cantidad_aprobada || ' a ' || p_cantidad_propuesta || ' ' || v_item.unidad || '.');
end;
$$;

create or replace function public.resolver_cambio(p_cambio_id uuid, p_decision text, p_comentario text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_cambio record; v_sol record; v_item record;
begin
  if not es_gerente() then raise exception 'No autorizado'; end if;
  if p_decision not in ('aprobado','rechazado') then raise exception 'Decisión inválida'; end if;
  select * into v_cambio from cambios_solicitados where id = p_cambio_id;
  if v_cambio is null then raise exception 'Cambio no encontrado'; end if;
  if v_cambio.estado <> 'pendiente' then raise exception 'Este cambio ya fue resuelto'; end if;
  select * into v_sol from solicitudes where id = v_cambio.solicitud_id;
  select * into v_item from solicitud_items where id = v_cambio.item_id;

  update cambios_solicitados set estado = p_decision, resuelto_por = auth.uid(),
    resuelto_comentario = p_comentario, resuelto_at = now() where id = p_cambio_id;

  if p_decision = 'aprobado' then
    perform set_config('erp.via_rpc', 'true', true);
    update solicitud_items set cantidad_aprobada = v_cambio.cantidad_propuesta where id = v_cambio.item_id;
    insert into eventos(solicitud_id, usuario_id, tipo, mensaje, detalle)
      values (v_sol.id, auth.uid(), 'cambio_aprobado',
        format('Cambio aprobado: "%s" ahora %s %s (antes %s).', v_item.descripcion, v_cambio.cantidad_propuesta, v_item.unidad, v_cambio.cantidad_actual),
        jsonb_build_object('item_id', v_item.id, 'de', v_cambio.cantidad_actual, 'a', v_cambio.cantidad_propuesta));
    perform notificar(v_sol.solicitante_id, v_sol.id, 'cambio_aprobado',
      'Cambio aprobado en solicitud N°' || v_sol.numero || ': "' || v_item.descripcion || '" ahora ' || v_cambio.cantidad_propuesta || ' ' || v_item.unidad || '.');
    perform notificar_rol(array['logistica','admin'], v_sol.id, 'cambio_aprobado',
      'Solicitud N°' || v_sol.numero || ': cambiaron "' || v_item.descripcion || '" de ' || v_cambio.cantidad_actual || ' a ' || v_cambio.cantidad_propuesta || ' ' || v_item.unidad || '.');
  else
    insert into eventos(solicitud_id, usuario_id, tipo, mensaje)
      values (v_sol.id, auth.uid(), 'cambio_rechazado', coalesce(p_comentario, 'Cambio rechazado.'));
    perform notificar(v_sol.solicitante_id, v_sol.id, 'cambio_rechazado',
      'Tu pedido de cambio en la solicitud N°' || v_sol.numero || ' fue rechazado.');
  end if;
end;
$$;

create or replace function public.marcar_estado_logistica(p_solicitud_id uuid, p_estado text)
returns void language plpgsql security definer set search_path = public as $$
declare v_sol record;
begin
  if not es_logistica() then raise exception 'No autorizado'; end if;
  if p_estado not in ('en_proceso','atendida','cerrada') then raise exception 'Estado inválido'; end if;
  select * into v_sol from solicitudes where id = p_solicitud_id;
  if v_sol is null then raise exception 'Solicitud no encontrada'; end if;
  if v_sol.estado not in ('aprobada','en_proceso','atendida') then
    raise exception 'La solicitud debe estar aprobada primero';
  end if;

  perform set_config('erp.via_rpc', 'true', true);
  update solicitudes set estado = p_estado where id = p_solicitud_id;
  insert into eventos(solicitud_id, usuario_id, tipo, mensaje)
    values (p_solicitud_id, auth.uid(), p_estado, 'Logística marcó la solicitud como "' || p_estado || '".');
  perform notificar(v_sol.solicitante_id, p_solicitud_id, p_estado,
    'Tu solicitud N°' || v_sol.numero || ' pasó a "' || p_estado || '".');
end;
$$;

create or replace function public.comentar_solicitud(p_solicitud_id uuid, p_mensaje text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_mensaje is null or length(trim(p_mensaje)) = 0 then raise exception 'Comentario vacío'; end if;
  if not exists (select 1 from solicitudes where id = p_solicitud_id) then
    raise exception 'Solicitud no encontrada';
  end if;
  insert into eventos(solicitud_id, usuario_id, tipo, mensaje)
    values (p_solicitud_id, auth.uid(), 'comentario', p_mensaje);
end;
$$;

create or replace function public.marcar_notificaciones_leidas(p_ids uuid[] default null)
returns void language sql security definer set search_path = public as $$
  update notificaciones set leida = true
  where user_id = auth.uid() and (p_ids is null or id = any(p_ids));
$$;

-- Por si tu proyecto no tiene ya el privilegio por defecto: aseguramos que
-- cualquier usuario logueado pueda invocar estas funciones (la seguridad real
-- la hace cada función internamente con es_admin()/es_gerente()/etc, más RLS).
grant execute on function
  public.enviar_solicitud(uuid),
  public.aprobar_solicitud(uuid, jsonb, text),
  public.rechazar_solicitud(uuid, text),
  public.solicitar_cambio(uuid, numeric, text),
  public.resolver_cambio(uuid, text, text),
  public.marcar_estado_logistica(uuid, text),
  public.comentar_solicitud(uuid, text),
  public.marcar_notificaciones_leidas(uuid[])
to authenticated;

-- ============================================================================
-- TIEMPO REAL: para que la campana de notificaciones y las pantallas se
-- actualicen solas (sin recargar la página), Supabase necesita que estas
-- tablas estén dentro de la publicación "supabase_realtime".
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array['solicitudes','solicitud_items','cambios_solicitados','eventos','notificaciones']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
