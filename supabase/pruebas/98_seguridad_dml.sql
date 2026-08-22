-- ============================================================
-- Pruebas de seguridad EJECUTANDO consultas reales
--
-- Las comprobaciones de catálogo (99_comprobaciones.sql) no bastan: dejaron
-- pasar dos fallos graves —un bypass de autorización en `miembros_invitar` y
-- la imposibilidad de crear grupos por el RETURNING de `groups`— porque
-- ninguno se ve mirando pg_policies. Aquí se hacen las consultas de verdad,
-- suplantando a usuarios concretos.
--
-- Se ejecuta SOLO en CI, sobre un PostgreSQL vacío y desechable, y todo va
-- dentro de una transacción que termina en ROLLBACK. Nunca contra una base
-- real.
-- ============================================================
\set ON_ERROR_STOP on

begin;

-- ------------------------------------------------------------
--  Montaje (como superusuario: RLS no aplica)
-- ------------------------------------------------------------
insert into auth.users (id, email) values
    ('11111111-1111-1111-1111-111111111111', 'ana@ejemplo.test'),
    ('22222222-2222-2222-2222-222222222222', 'bruno@ejemplo.test'),
    ('33333333-3333-3333-3333-333333333333', 'intruso@ejemplo.test');

-- El trigger de 0001 ya habrá creado los perfiles; esto solo fija el nombre.
insert into public.profiles (id, display_name) values
    ('11111111-1111-1111-1111-111111111111', 'Ana'),
    ('22222222-2222-2222-2222-222222222222', 'Bruno'),
    ('33333333-3333-3333-3333-333333333333', 'Intruso')
on conflict (id) do update set display_name = excluded.display_name;

-- Grupo compartido por Ana y Bruno. El intruso no está en ninguno.
insert into public.groups (id, name, created_by) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Casa', '11111111-1111-1111-1111-111111111111');

insert into public.group_members (group_id, user_id, role) values
    ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'owner'),
    ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'member')
on conflict do nothing;

insert into public.expenses (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        50.00, 'Compra', 'súper', 0.5, current_date, 'prueba-1');

-- ============================================================
--  1. UN MIEMBRO VE LO SUYO
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
begin
    if auth.uid() <> '11111111-1111-1111-1111-111111111111' then
        raise exception 'La suplantación no funciona: auth.uid() = %', auth.uid();
    end if;
    if (select count(*) from public.groups) <> 1 then
        raise exception 'Ana debería ver 1 grupo, ve %', (select count(*) from public.groups);
    end if;
    if (select count(*) from public.expenses) <> 1 then
        raise exception 'Ana debería ver 1 gasto, ve %', (select count(*) from public.expenses);
    end if;
    if (select count(*) from public.profiles) <> 2 then
        raise exception 'Ana debería ver 2 perfiles (ella y Bruno), ve %',
            (select count(*) from public.profiles);
    end if;
end $$;

-- ============================================================
--  2. CREAR UN GRUPO CON insert(...).select().single()
--
--  Es exactamente lo que hace js/supabase-data.js. Falla si la política de
--  SELECT de `groups` no contempla al creador, porque en un
--  INSERT ... RETURNING la política de SELECT se evalúa ANTES de que corra
--  el trigger AFTER que apunta al creador en group_members.
-- ============================================================
do $$
declare
    devuelto uuid;
begin
    insert into public.groups (name) values ('Viaje')
    returning id into devuelto;

    if devuelto is null then
        raise exception 'insert ... returning no devolvió la fila: crear un grupo fallaría';
    end if;

    if not exists (select 1 from public.group_members
                   where group_id = devuelto
                     and user_id = auth.uid() and role = 'owner') then
        raise exception 'El creador no ha quedado como owner del grupo nuevo';
    end if;
end $$;

-- ============================================================
--  3. EL INTRUSO NO VE NADA
-- ============================================================
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';

do $$
begin
    if (select count(*) from public.groups) <> 0 then
        raise exception 'FUGA: el intruso ve % grupos', (select count(*) from public.groups);
    end if;
    if (select count(*) from public.expenses) <> 0 then
        raise exception 'FUGA: el intruso ve % gastos', (select count(*) from public.expenses);
    end if;
    if (select count(*) from public.settlements) <> 0 then
        raise exception 'FUGA: el intruso ve liquidaciones ajenas';
    end if;
    if (select count(*) from public.group_members) <> 0 then
        raise exception 'FUGA: el intruso ve membresías ajenas';
    end if;
    -- Solo debe verse a sí mismo.
    if (select count(*) from public.profiles) <> 1 then
        raise exception 'FUGA: el intruso ve % perfiles', (select count(*) from public.profiles);
    end if;
end $$;

-- ============================================================
--  4. EL INTRUSO NO PUEDE AUTOINVITARSE
--
--  Este es el ataque que una versión anterior de `miembros_invitar` permitía:
--  su rama `not exists (select 1 from group_members ...)` era siempre TRUE
--  para un grupo ajeno, porque la subconsulta pasa por RLS y devuelve vacío.
-- ============================================================
do $$
declare
    entro boolean := false;
begin
    begin
        insert into public.group_members (group_id, user_id, role)
        values ('aaaaaaaa-0000-0000-0000-000000000001',
                '33333333-3333-3333-3333-333333333333', 'member');
        entro := true;
    exception
        when insufficient_privilege then entro := false;
    end;

    if entro then
        raise exception
            'FALLO DE SEGURIDAD: un usuario ajeno ha podido apuntarse al grupo de otra persona';
    end if;
end $$;

-- ...ni escribir gastos en un grupo ajeno.
do $$
declare
    entro boolean := false;
begin
    begin
        insert into public.expenses (group_id, paid_by, amount, description, category, payer_share, spent_on)
        values ('aaaaaaaa-0000-0000-0000-000000000001',
                '33333333-3333-3333-3333-333333333333', 9.99, 'Colado', 'otros', 0.5, current_date);
        entro := true;
    exception
        when insufficient_privilege then entro := false;
    end;

    if entro then
        raise exception 'FALLO DE SEGURIDAD: un usuario ajeno ha escrito un gasto en un grupo ajeno';
    end if;
end $$;

-- ...ni borrar lo de otros (un delete sin permiso afecta a 0 filas).
do $$
declare
    tocadas int;
begin
    with borradas as (
        delete from public.expenses
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        returning 1
    )
    select count(*) into tocadas from borradas;

    if tocadas <> 0 then
        raise exception 'FALLO DE SEGURIDAD: un usuario ajeno ha borrado % gastos', tocadas;
    end if;
end $$;

-- ============================================================
--  5. EL UPSERT DE LA COLA OFFLINE FUNCIONA CON RLS ACTIVA
--
--  `upsert(onConflict:'client_id')` se traduce a ON CONFLICT DO UPDATE, y
--  necesita política de INSERT **y** de UPDATE. Además comprueba que el
--  índice único de client_id permite inferir el conflicto.
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

do $$
declare
    cuantos int;
begin
    -- Alta nueva.
    insert into public.expenses
        (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
            12.00, 'Cena', 'comer fuera', 0.5, current_date, 'cola-1')
    on conflict (client_id) do update set amount = excluded.amount;

    -- Reintento de la misma tarea: no debe duplicar.
    insert into public.expenses
        (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
            12.00, 'Cena', 'comer fuera', 0.5, current_date, 'cola-1')
    on conflict (client_id) do update set amount = excluded.amount;

    select count(*) into cuantos from public.expenses where client_id = 'cola-1';
    if cuantos <> 1 then
        raise exception 'El upsert por client_id ha duplicado la fila (% copias)', cuantos;
    end if;
end $$;

-- ...y Bruno puede editar y borrar un gasto que pagó Ana (mismo grupo).
do $$
declare
    tocadas int;
begin
    with cambiadas as (
        update public.expenses set amount = 55.00 where client_id = 'prueba-1' returning 1
    )
    select count(*) into tocadas from cambiadas;

    if tocadas <> 1 then
        raise exception 'Un miembro no puede editar el gasto de la otra persona del grupo';
    end if;
end $$;

reset role;
rollback;

select 'Pruebas de seguridad DML superadas' as resultado;
