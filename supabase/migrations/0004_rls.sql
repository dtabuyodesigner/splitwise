-- ============================================================
-- 0004 · Row Level Security
--
-- NO APLICADA. Es la migración con MÁS RIESGO DE ROTURA de las cinco:
-- activar RLS sin políticas correctas deja la aplicación en blanco.
--
-- ORDEN OBLIGATORIO: 0002 (group_members) y su backfill TIENEN que estar
-- aplicados y comprobados antes que esto. Si un grupo se queda sin filas en
-- group_members, desaparece para todo el mundo en cuanto se ejecute este
-- archivo.
--
-- Ver supabase/README.md §6 para el procedimiento de validación y §8 para
-- la marcha atrás.
--
-- Principio: nadie ve ni toca nada de un grupo del que no es miembro.
-- ============================================================

-- ------------------------------------------------------------
-- Activación
-- ------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.groups        enable row level security;
alter table public.group_members enable row level security;
alter table public.expenses      enable row level security;
alter table public.settlements   enable row level security;

-- Deja fuera de duda que ni el rol anónimo ni el autenticado tienen acceso
-- por GRANT: todo pasa por las políticas.
revoke all on public.profiles, public.groups, public.group_members,
              public.expenses, public.settlements from anon;

grant select, insert, update, delete
    on public.profiles, public.groups, public.group_members,
       public.expenses, public.settlements
    to authenticated;

-- ------------------------------------------------------------
-- profiles
--
-- Se ve el perfil propio y el de quien comparte algún grupo contigo. Así
-- deja de ser posible enumerar a todos los usuarios de la instancia, que es
-- lo que permite hoy `profiles.select('*')`.
-- ------------------------------------------------------------
drop policy if exists profiles_leer on public.profiles;
create policy profiles_leer on public.profiles
    for select to authenticated
    using (
        id = auth.uid()
        or exists (
            select 1
            from public.group_members mio
            join public.group_members suyo on suyo.group_id = mio.group_id
            where mio.user_id = auth.uid() and suyo.user_id = public.profiles.id
        )
    );

drop policy if exists profiles_modificar_el_mio on public.profiles;
create policy profiles_modificar_el_mio on public.profiles
    for update to authenticated
    using (id = auth.uid())
    with check (id = auth.uid());

-- El alta la hace el trigger de 0001 (SECURITY DEFINER). Se permite también
-- por si el trigger no llegó a ejecutarse, pero solo para uno mismo.
drop policy if exists profiles_crear_el_mio on public.profiles;
create policy profiles_crear_el_mio on public.profiles
    for insert to authenticated
    with check (id = auth.uid());

-- Nadie borra perfiles desde el cliente: se borran en cascada con auth.users.

-- ------------------------------------------------------------
-- groups
-- ------------------------------------------------------------
drop policy if exists groups_leer_los_mios on public.groups;
create policy groups_leer_los_mios on public.groups
    for select to authenticated
    using (public.es_miembro(id));

drop policy if exists groups_crear on public.groups;
create policy groups_crear on public.groups
    for insert to authenticated
    with check (created_by is null or created_by = auth.uid());

drop policy if exists groups_modificar on public.groups;
create policy groups_modificar on public.groups
    for update to authenticated
    using (public.es_miembro(id))
    with check (public.es_miembro(id));

-- Borrar un grupo se limita a quien lo creó: es una acción en cascada que
-- destruye los gastos de las dos personas.
drop policy if exists groups_borrar on public.groups;
create policy groups_borrar on public.groups
    for delete to authenticated
    using (
        exists (
            select 1 from public.group_members
            where group_id = public.groups.id
              and user_id = auth.uid()
              and role = 'owner'
        )
    );

-- ------------------------------------------------------------
-- group_members
--
-- Se ven los miembros de los grupos propios. Invitar a alguien lo puede
-- hacer cualquier miembro; expulsar, solo el propietario (o uno mismo,
-- para poder salirse).
-- ------------------------------------------------------------
drop policy if exists miembros_leer on public.group_members;
create policy miembros_leer on public.group_members
    for select to authenticated
    using (public.es_miembro(group_id));

drop policy if exists miembros_invitar on public.group_members;
create policy miembros_invitar on public.group_members
    for insert to authenticated
    with check (
        -- alta del propio creador al crear el grupo...
        (user_id = auth.uid() and not exists (
            select 1 from public.group_members m where m.group_id = group_members.group_id
        ))
        -- ...o invitación hecha por alguien que ya es miembro
        or public.es_miembro(group_id)
    );

drop policy if exists miembros_expulsar on public.group_members;
create policy miembros_expulsar on public.group_members
    for delete to authenticated
    using (
        user_id = auth.uid()
        or exists (
            select 1 from public.group_members m
            where m.group_id = group_members.group_id
              and m.user_id = auth.uid()
              and m.role = 'owner'
        )
    );

-- ------------------------------------------------------------
-- expenses
--
-- Leer y modificar: cualquier miembro del grupo. Es intencionado — las dos
-- personas de una pareja corrigen los gastos de la otra a diario, y esa
-- posibilidad ya existe hoy. Lo que cambia es que ahora hace falta ser
-- MIEMBRO DEL GRUPO.
--
-- Al insertar se comprueba además que el pagador declarado también sea
-- miembro: así no se pueden crear gastos a nombre de un extraño.
-- ------------------------------------------------------------
drop policy if exists gastos_leer on public.expenses;
create policy gastos_leer on public.expenses
    for select to authenticated
    using (public.es_miembro(group_id));

drop policy if exists gastos_crear on public.expenses;
create policy gastos_crear on public.expenses
    for insert to authenticated
    with check (public.es_miembro(group_id) and public.es_miembro(group_id, paid_by));

drop policy if exists gastos_modificar on public.expenses;
create policy gastos_modificar on public.expenses
    for update to authenticated
    using (public.es_miembro(group_id))
    with check (public.es_miembro(group_id) and public.es_miembro(group_id, paid_by));

drop policy if exists gastos_borrar on public.expenses;
create policy gastos_borrar on public.expenses
    for delete to authenticated
    using (public.es_miembro(group_id));

-- ------------------------------------------------------------
-- settlements
-- ------------------------------------------------------------
drop policy if exists liquidaciones_leer on public.settlements;
create policy liquidaciones_leer on public.settlements
    for select to authenticated
    using (public.es_miembro(group_id));

drop policy if exists liquidaciones_crear on public.settlements;
create policy liquidaciones_crear on public.settlements
    for insert to authenticated
    with check (
        public.es_miembro(group_id)
        and public.es_miembro(group_id, from_user)
        and public.es_miembro(group_id, to_user)
    );

drop policy if exists liquidaciones_modificar on public.settlements;
create policy liquidaciones_modificar on public.settlements
    for update to authenticated
    using (public.es_miembro(group_id))
    with check (
        public.es_miembro(group_id)
        and public.es_miembro(group_id, from_user)
        and public.es_miembro(group_id, to_user)
    );

drop policy if exists liquidaciones_borrar on public.settlements;
create policy liquidaciones_borrar on public.settlements
    for delete to authenticated
    using (public.es_miembro(group_id));
