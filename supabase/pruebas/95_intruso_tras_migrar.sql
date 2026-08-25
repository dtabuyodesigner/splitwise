-- ============================================================
-- Tras migrar desde el esquema histórico: ¿queda alguna puerta abierta?
--
-- Este archivo se ejecuta SOLO en el escenario de actualización, cuando los
-- datos históricos ya están en la base y las migraciones ya se han aplicado.
--
-- Lo que comprueba es exactamente el riesgo del hallazgo: las políticas
-- antiguas concedían acceso global con `using (true)`. Si alguna hubiera
-- sobrevivido, PostgreSQL la combinaría con OR y una tercera cuenta seguiría
-- viéndolo todo. Aquí se crea esa tercera cuenta y se intenta.
--
-- Todo va dentro de una transacción que termina en ROLLBACK.
-- ============================================================
\set ON_ERROR_STOP on

begin;

-- Una tercera persona que no pertenece a ningún grupo.
insert into auth.users (id, email, raw_user_meta_data) values
    ('33333333-3333-3333-3333-333333333333', 'intruso@ejemplo.test',
     '{"display_name":"Intruso"}');

-- El backfill ya se ha aplicado, así que Dani y Pilar SÍ ven sus tres
-- grupos (lo comprueba 93). Lo que se prueba aquí es que una tercera cuenta,
-- que no tiene ninguna membresía, no ve ni toca nada.
do $$
declare
    filas integer;
begin
    select count(*) into filas from public.group_members;
    if filas <> 6 then
        raise exception 'Se esperaban 6 membresías tras el backfill y hay %', filas;
    end if;
    raise notice 'Membresías tras el backfill: %', filas;
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';

do $$
declare
    g integer; e integer; s integer; p integer; m integer;
begin
    select count(*) into g from public.groups;
    select count(*) into e from public.expenses;
    select count(*) into s from public.settlements;
    select count(*) into p from public.profiles;
    select count(*) into m from public.group_members;

    if g <> 0 then
        raise exception 'FUGA: una cuenta ajena ve % grupos históricos. '
                        'Probablemente ha sobrevivido una política using(true).', g;
    end if;
    if e <> 0 then
        raise exception 'FUGA: una cuenta ajena ve % gastos históricos', e;
    end if;
    if s <> 0 then
        raise exception 'FUGA: una cuenta ajena ve % liquidaciones históricas', s;
    end if;
    if m <> 0 then
        raise exception 'FUGA: una cuenta ajena ve % membresías', m;
    end if;
    -- Solo debe verse a sí misma.
    if p <> 1 then
        raise exception 'FUGA: una cuenta ajena ve % perfiles (debería ver solo el suyo)', p;
    end if;

    raise notice '[H01] ok — tras migrar, una cuenta ajena no ve ningún dato histórico';
end $$;

-- Tampoco debe poder escribir en los datos históricos.
do $$
declare
    escritas integer := 0;
    tocadas  integer;
begin
    -- El id del grupo va LITERAL, no leído de public.groups: el intruso no ve
    -- ningún grupo, así que un `insert ... select from public.groups` habría
    -- insertado cero filas sin lanzar ningún error, y eso no demuestra nada.
    -- Aquí el INSERT sí intenta escribir una fila concreta y tiene que ser
    -- rechazado por la política.
    begin
        with metidas as (
            insert into public.expenses
                (group_id, paid_by, amount, description, category, payer_share, spent_on)
            values ('aaaaaaaa-0000-0000-0000-0000000000f0',
                    '33333333-3333-3333-3333-333333333333',
                    1, 'colado', 'otros', 0.5, current_date)
            returning 1
        )
        select count(*) into escritas from metidas;
    exception when others then
        escritas := 0;   -- rechazado: es lo que debe pasar
    end;

    if escritas > 0 then
        raise exception 'FUGA: una cuenta ajena ha escrito % gasto(s) en un grupo histórico', escritas;
    end if;
    raise notice '[H02] ok — tras migrar, una cuenta ajena no puede escribir gastos';

    with borradas as (delete from public.expenses returning 1)
    select count(*) into tocadas from borradas;

    if tocadas <> 0 then
        raise exception 'FUGA: una cuenta ajena ha borrado % gastos históricos', tocadas;
    end if;
    raise notice '[H03] ok — tras migrar, una cuenta ajena no puede borrar gastos';
end $$;

reset role;

-- Y los datos históricos siguen enteros: la migración no ha perdido nada.
do $$
declare
    e integer; s integer; g integer; pr integer;
begin
    select count(*) into e  from public.expenses;
    select count(*) into s  from public.settlements;
    select count(*) into g  from public.groups;
    select count(*) into pr from public.profiles;

    if e <> 53 then raise exception 'Se han perdido gastos: hay % y debería haber 53', e; end if;
    if s <> 1  then raise exception 'Se han perdido liquidaciones: hay %', s; end if;
    if g <> 3  then raise exception 'Se han perdido grupos: hay %', g; end if;

    raise notice '[H04] ok — los datos históricos siguen enteros: % gastos, % liquidaciones, % grupos, % perfiles',
        e, s, g, pr;
end $$;

rollback;

select 'Ninguna política histórica ha sobrevivido a la migración' as resultado;
