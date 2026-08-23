-- ============================================================
-- Pruebas de seguridad EJECUTANDO consultas reales
--
-- Las comprobaciones de catálogo (99_comprobaciones.sql) no bastan: dejaron
-- pasar un bypass de autorización en un WITH CHECK y un INSERT ... RETURNING
-- bloqueado, porque ninguno de los dos se ve mirando pg_policies. Aquí se
-- hacen las consultas de verdad, suplantando a usuarios concretos.
--
-- Se ejecuta SOLO en CI, sobre un PostgreSQL vacío y desechable, y todo va
-- dentro de una transacción que termina en ROLLBACK. Nunca contra una base
-- real.
--
-- Cada aserción lleva un identificador ([A01], [F05]...). Si algo falla, el
-- error dice exactamente cuál, y las que han pasado quedan en el log como
-- NOTICE. Al final se imprime el recuento.
-- ============================================================
\set ON_ERROR_STOP on

begin;

-- ------------------------------------------------------------
--  Utilidad de aserción
--
--  SECURITY DEFINER para poder dejar constancia en el registro aunque quien
--  la invoque sea un rol sin privilegios.
-- ------------------------------------------------------------
create table public.registro_aserciones (
    id          text primary key,
    descripcion text not null,
    momento     timestamptz not null default clock_timestamp()
);

create or replace function public.afirmar(p_id text, p_ok boolean, p_desc text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_ok is null or not p_ok then
        raise exception '[%] FALLA — %', p_id, p_desc using errcode = 'assert_failure';
    end if;
    insert into public.registro_aserciones (id, descripcion) values (p_id, p_desc);
    raise notice '[%] ok — %', p_id, p_desc;
end;
$$;

-- ------------------------------------------------------------
--  Montaje (como superusuario: RLS no aplica)
-- ------------------------------------------------------------
insert into auth.users (id, email) values
    ('11111111-1111-1111-1111-111111111111', 'ana@ejemplo.test'),
    ('22222222-2222-2222-2222-222222222222', 'bruno@ejemplo.test'),
    ('33333333-3333-3333-3333-333333333333', 'intruso@ejemplo.test'),
    ('44444444-4444-4444-4444-444444444444', 'carla@ejemplo.test');

insert into public.profiles (id, display_name) values
    ('11111111-1111-1111-1111-111111111111', 'Ana'),
    ('22222222-2222-2222-2222-222222222222', 'Bruno'),
    ('33333333-3333-3333-3333-333333333333', 'Intruso'),
    ('44444444-4444-4444-4444-444444444444', 'Carla')
on conflict (id) do update set display_name = excluded.display_name;

-- "Casa": Ana (owner) y Bruno. Un solo propietario: se usa para las pruebas
-- del último propietario.
insert into public.groups (id, name, created_by) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Casa',
     '11111111-1111-1111-1111-111111111111');

-- "Propiedad": Ana (owner), Bruno y Carla. Se usa para transferir la
-- propiedad y expulsar sin tocar "Casa".
insert into public.groups (id, name, created_by) values
    ('aaaaaaaa-0000-0000-0000-000000000002', 'Propiedad',
     '11111111-1111-1111-1111-111111111111');

-- "Individual": SOLO Ana. La regla de negocio admite grupos de una persona,
-- y Bruno no debe verlo pese a compartir otros grupos con ella.
insert into public.groups (id, name, created_by) values
    ('aaaaaaaa-0000-0000-0000-000000000003', 'Individual',
     '11111111-1111-1111-1111-111111111111');

-- "Trio": Ana, Bruno y Carla. Tres participantes.
insert into public.groups (id, name, created_by) values
    ('aaaaaaaa-0000-0000-0000-000000000004', 'Trio',
     '11111111-1111-1111-1111-111111111111');

insert into public.group_members (group_id, user_id, role) values
    ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'owner'),
    ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'member'),
    ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'owner'),
    ('aaaaaaaa-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'member'),
    ('aaaaaaaa-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'member'),
    ('aaaaaaaa-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'owner'),
    ('aaaaaaaa-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'owner'),
    ('aaaaaaaa-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222', 'member'),
    ('aaaaaaaa-0000-0000-0000-000000000004', '44444444-4444-4444-4444-444444444444', 'member')
on conflict do nothing;

insert into public.expenses
    (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        50.00, 'Compra', 'súper', 0.5, current_date, 'prueba-1');

-- ============================================================
--  S · El propio entorno de pruebas
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
begin
    perform public.afirmar('S01',
        auth.uid() = '11111111-1111-1111-1111-111111111111',
        'la suplantación de usuario funciona (auth.uid() devuelve el sub del JWT)');
end $$;

do $$
declare
    pudo boolean := false;
    est  text;
begin
    begin
        perform 1 from auth.users limit 1;
        pudo := true;
    exception when insufficient_privilege then
        get stacked diagnostics est = returned_sqlstate;
        pudo := false;
    end;

    perform public.afirmar('S02', not pudo,
        'poder llamar a auth.uid() NO da acceso de lectura a auth.users');
end $$;

-- ============================================================
--  A · Aislamiento de lectura (Ana)
-- ============================================================
do $$
begin
    perform public.afirmar('A01', (select count(*) from public.groups) = 4,
        'Ana ve exactamente sus 4 grupos (Casa, Propiedad, Individual y Trio)');

    perform public.afirmar('A02', (select count(*) from public.expenses) = 1,
        'Ana ve el gasto de su grupo');

    perform public.afirmar('A03', (select count(*) from public.profiles) = 3,
        'Ana ve solo los perfiles con los que comparte grupo (ella, Bruno y Carla)');

    perform public.afirmar('A04', (select count(*) from public.group_members) = 9,
        'Ana ve las membresías de sus cuatro grupos');

    perform public.afirmar('A05',
        not exists (select 1 from public.profiles
                    where id = '33333333-3333-3333-3333-333333333333'),
        'Ana NO ve el perfil del intruso');
end $$;

-- ============================================================
--  G · La pertenencia se define grupo a grupo
--
--  Regla de negocio: NO se puede asumir que todos los perfiles pertenecen a
--  todos los grupos. Hay grupos de dos, alguno de tres y alguno individual.
-- ============================================================
do $$
begin
    perform public.afirmar('G01',
        exists (select 1 from public.groups
                where id = 'aaaaaaaa-0000-0000-0000-000000000003'),
        'un grupo individual es válido y su dueña lo ve');

    perform public.afirmar('G02',
        (select count(*) from public.group_members
         where group_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 1,
        'el grupo individual tiene exactamente un miembro');

    perform public.afirmar('G03',
        (select count(*) from public.group_members
         where group_id = 'aaaaaaaa-0000-0000-0000-000000000004') = 3,
        'un grupo puede tener tres participantes');
end $$;

-- Ana apunta un gasto en su grupo individual: tiene que funcionar.
do $$
declare
    entro boolean := false;
begin
    begin
        insert into public.expenses
            (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
        values ('aaaaaaaa-0000-0000-0000-000000000003',
                '11111111-1111-1111-1111-111111111111', 8.40, 'Café', 'comer fuera',
                1, current_date, 'solo-1');
        entro := true;
    exception when others then
        entro := false;
    end;

    perform public.afirmar('G04', entro,
        'en un grupo individual SÍ se pueden apuntar gastos');
end $$;

-- Y Bruno, que comparte otros grupos con Ana, NO debe ver ni tocar ese grupo.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

do $$
begin
    perform public.afirmar('G05',
        not exists (select 1 from public.groups
                    where id = 'aaaaaaaa-0000-0000-0000-000000000003'),
        'compartir OTROS grupos con alguien NO da acceso a su grupo individual');

    perform public.afirmar('G06',
        not exists (select 1 from public.expenses where client_id = 'solo-1'),
        'Bruno tampoco ve los gastos del grupo individual de Ana');

    perform public.afirmar('G07',
        (select count(*) from public.groups) = 3,
        'Bruno ve sus 3 grupos, no los 4 de Ana');
end $$;

do $$
declare
    entro boolean := false;
begin
    begin
        insert into public.expenses
            (group_id, paid_by, amount, description, category, payer_share, spent_on)
        values ('aaaaaaaa-0000-0000-0000-000000000003',
                '22222222-2222-2222-2222-222222222222', 1.00, 'Colado', 'otros',
                0.5, current_date);
        entro := true;
    exception when insufficient_privilege then
        entro := false;
    end;

    perform public.afirmar('G08', not entro,
        'ATAQUE: Bruno NO puede escribir en el grupo individual de Ana');
end $$;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- ============================================================
--  B · Crear grupo con insert(...).select().single()
--
--  Es exactamente lo que hace js/supabase-data.js. Falla si la política de
--  SELECT de `groups` no contempla al creador: en un INSERT ... RETURNING la
--  política de SELECT se evalúa ANTES de que corra el trigger AFTER que
--  apunta al creador en group_members.
-- ============================================================
do $$
declare
    devuelto uuid;
begin
    insert into public.groups (name) values ('Viaje') returning id into devuelto;

    perform public.afirmar('B01', devuelto is not null,
        'insert ... returning devuelve la fila del grupo recién creado');

    perform public.afirmar('B02',
        exists (select 1 from public.group_members
                where group_id = devuelto and user_id = auth.uid() and role = 'owner'),
        'quien crea el grupo queda registrado como propietario');

    perform public.afirmar('B03',
        (select count(*) from public.group_members where group_id = devuelto) = 1,
        'crear un grupo mete SOLO a su creador: nadie más entra automáticamente');
end $$;

-- ============================================================
--  C · El intruso no ve nada
-- ============================================================
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';

do $$
begin
    perform public.afirmar('C01', (select count(*) from public.groups) = 0,
        'el intruso no ve ningún grupo');

    perform public.afirmar('C02', (select count(*) from public.expenses) = 0,
        'el intruso no ve ningún gasto');

    perform public.afirmar('C03', (select count(*) from public.settlements) = 0,
        'el intruso no ve ninguna liquidación');

    perform public.afirmar('C04', (select count(*) from public.group_members) = 0,
        'el intruso no ve ninguna membresía');

    perform public.afirmar('C05', (select count(*) from public.profiles) = 1,
        'el intruso solo se ve a sí mismo');
end $$;

-- ============================================================
--  D · Ataques del intruso
--
--  D01 es literalmente el bypass que tenía una versión anterior de
--  `miembros_invitar`: su rama `not exists (select 1 from group_members ...)`
--  era siempre TRUE para un grupo ajeno, porque la subconsulta pasa por RLS
--  y devuelve vacío para quien no es miembro.
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
    exception when insufficient_privilege then
        entro := false;
    end;

    perform public.afirmar('D01', not entro,
        'ATAQUE: el intruso NO puede autoinvitarse a un grupo ajeno');
end $$;

do $$
declare
    entro boolean := false;
begin
    begin
        insert into public.expenses
            (group_id, paid_by, amount, description, category, payer_share, spent_on)
        values ('aaaaaaaa-0000-0000-0000-000000000001',
                '33333333-3333-3333-3333-333333333333', 9.99, 'Colado', 'otros',
                0.5, current_date);
        entro := true;
    exception when insufficient_privilege then
        entro := false;
    end;

    perform public.afirmar('D02', not entro,
        'ATAQUE: el intruso NO puede escribir un gasto en un grupo ajeno');
end $$;

do $$
declare
    tocadas integer;
begin
    with borradas as (
        delete from public.expenses
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        returning 1
    )
    select count(*) into tocadas from borradas;

    perform public.afirmar('D03', tocadas = 0,
        'ATAQUE: el intruso NO puede borrar gastos ajenos');
end $$;

do $$
declare
    tocadas integer;
begin
    with cambiadas as (
        update public.group_members set role = 'owner'
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        returning 1
    )
    select count(*) into tocadas from cambiadas;

    perform public.afirmar('D04', tocadas = 0,
        'ATAQUE: el intruso NO puede cambiar roles en un grupo ajeno');
end $$;

do $$
declare
    tocadas integer;
begin
    with fuera as (
        delete from public.group_members
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        returning 1
    )
    select count(*) into tocadas from fuera;

    perform public.afirmar('D05', tocadas = 0,
        'ATAQUE: el intruso NO puede expulsar a nadie de un grupo ajeno');
end $$;

do $$
declare
    tocadas integer;
begin
    with renombradas as (
        update public.groups set name = 'Secuestrado'
        where id = 'aaaaaaaa-0000-0000-0000-000000000001'
        returning 1
    )
    select count(*) into tocadas from renombradas;

    perform public.afirmar('D06', tocadas = 0,
        'ATAQUE: el intruso NO puede renombrar un grupo ajeno');
end $$;

-- ============================================================
--  E · La cola offline y la edición entre miembros
-- ============================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

do $$
declare
    cuantos integer;
begin
    -- Alta y reintento de la misma tarea: no debe duplicar.
    insert into public.expenses
        (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
            12.00, 'Cena', 'comer fuera', 0.5, current_date, 'cola-1')
    on conflict (client_id) do update set amount = excluded.amount;

    insert into public.expenses
        (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
            12.00, 'Cena', 'comer fuera', 0.5, current_date, 'cola-1')
    on conflict (client_id) do update set amount = excluded.amount;

    select count(*) into cuantos from public.expenses where client_id = 'cola-1';

    perform public.afirmar('E01', cuantos = 1,
        'el upsert por client_id de la cola offline es idempotente con RLS activa');
end $$;

do $$
declare
    tocadas integer;
begin
    with cambiadas as (
        update public.expenses set amount = 55.00 where client_id = 'prueba-1' returning 1
    )
    select count(*) into tocadas from cambiadas;

    perform public.afirmar('E02', tocadas = 1,
        'un miembro SÍ puede editar el gasto que pagó la otra persona del grupo');
end $$;

-- ============================================================
--  F · Invariantes del propietario
--
--  "Un grupo conserva al menos un propietario" no se puede expresar con RLS:
--  RLS decide fila a fila y esta regla depende de las demás filas. La impone
--  el trigger antes_de_perder_propietario.
-- ============================================================

-- F01 y F02: Bruno es miembro normal de "Propiedad".
do $$
declare
    tocadas integer;
begin
    with cambiadas as (
        update public.group_members set role = 'owner'
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000002'
          and user_id = '22222222-2222-2222-2222-222222222222'
        returning 1
    )
    select count(*) into tocadas from cambiadas;

    perform public.afirmar('F01', tocadas = 0,
        'un miembro normal NO puede ascenderse a propietario');
end $$;

do $$
declare
    tocadas integer;
begin
    with fuera as (
        delete from public.group_members
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000002'
          and user_id = '44444444-4444-4444-4444-444444444444'
        returning 1
    )
    select count(*) into tocadas from fuera;

    perform public.afirmar('F02', tocadas = 0,
        'un miembro normal NO puede expulsar a otra persona');
end $$;

-- F03 y F04: Ana es propietaria de "Propiedad".
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
    tocadas integer;
begin
    with cambiadas as (
        update public.group_members set role = 'owner'
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000002'
          and user_id = '44444444-4444-4444-4444-444444444444'
        returning 1
    )
    select count(*) into tocadas from cambiadas;

    perform public.afirmar('F03', tocadas = 1,
        'un propietario SÍ puede nombrar propietaria a otra persona (transferencia)');
end $$;

do $$
declare
    tocadas integer;
begin
    with fuera as (
        delete from public.group_members
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000002'
          and user_id = '22222222-2222-2222-2222-222222222222'
        returning 1
    )
    select count(*) into tocadas from fuera;

    perform public.afirmar('F04', tocadas = 1,
        'un propietario SÍ puede expulsar a un miembro normal');
end $$;

-- F05 y F06: en "Casa", Ana es la ÚNICA propietaria.
do $$
declare
    bloqueado boolean := false;
    estado    text := '(ninguno)';
begin
    begin
        update public.group_members set role = 'member'
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
          and user_id = '11111111-1111-1111-1111-111111111111';
    exception when others then
        get stacked diagnostics estado = returned_sqlstate;
        bloqueado := true;
    end;

    raise notice '     F05 · SQLSTATE devuelto: %', estado;

    perform public.afirmar('F05', bloqueado,
        'el ÚLTIMO propietario NO puede degradarse a miembro');

    perform public.afirmar('F05b',
        (select count(*) from public.group_members
         where group_id = 'aaaaaaaa-0000-0000-0000-000000000001' and role = 'owner') = 1,
        'tras el intento, "Casa" conserva a su propietaria');
end $$;

do $$
declare
    bloqueado boolean := false;
    estado    text := '(ninguno)';
begin
    begin
        delete from public.group_members
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000001'
          and user_id = '11111111-1111-1111-1111-111111111111';
    exception when others then
        get stacked diagnostics estado = returned_sqlstate;
        bloqueado := true;
    end;

    raise notice '     F06 · SQLSTATE devuelto: %', estado;

    perform public.afirmar('F06', bloqueado,
        'el ÚLTIMO propietario NO puede abandonar el grupo');

    perform public.afirmar('F06b',
        (select count(*) from public.group_members
         where group_id = 'aaaaaaaa-0000-0000-0000-000000000001' and role = 'owner') = 1,
        'tras el intento de salida, "Casa" sigue teniendo propietaria');
end $$;

-- F07: en "Propiedad" la propiedad ya se transfirió a Carla (F03), así que
-- ahora Ana sí puede marcharse.
do $$
declare
    tocadas integer;
begin
    with fuera as (
        delete from public.group_members
        where group_id = 'aaaaaaaa-0000-0000-0000-000000000002'
          and user_id = '11111111-1111-1111-1111-111111111111'
        returning 1
    )
    select count(*) into tocadas from fuera;

    perform public.afirmar('F07', tocadas = 1,
        'tras transferir la propiedad, el propietario anterior SÍ puede salir');
end $$;

reset role;

do $$
begin
    perform public.afirmar('F08',
        (select count(*) from public.group_members
         where group_id = 'aaaaaaaa-0000-0000-0000-000000000002' and role = 'owner') >= 1,
        '"Propiedad" ha conservado al menos un propietario en todo momento');
end $$;

-- ------------------------------------------------------------
--  Recuento
-- ------------------------------------------------------------
select count(*) || ' aserciones DML superadas' as resultado
from public.registro_aserciones;

select string_agg(id, ' ' order by id) as aserciones
from public.registro_aserciones;

rollback;
