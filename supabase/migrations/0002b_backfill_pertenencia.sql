-- ============================================================
-- 0002b · Backfill de la pertenencia a los grupos existentes
--
-- NO APLICADO. **Este archivo hay que rellenarlo a mano antes de usarlo.**
--
-- Se aplica SIEMPRE en la misma transacción que 0002:
--
--     psql "$URL" -v ON_ERROR_STOP=1 --single-transaction \
--       -f supabase/migrations/0002_group_members.sql \
--       -f supabase/migrations/0002b_backfill_pertenencia.sql
--
-- ------------------------------------------------------------
-- POR QUÉ NO HAY UN BACKFILL AUTOMÁTICO
--
-- La regla de negocio es que la pertenencia se define grupo a grupo:
-- habrá grupos de dos personas, alguno con una tercera, y alguno individual.
-- Cualquier regla automática se equivoca en cuanto aparece la excepción, y
-- equivocarse aquí significa una de dos cosas, las dos malas:
--
--   · dar acceso a los gastos de alguien a quien no le corresponden;
--   · o dejar a una persona fuera de un grupo que sí es suyo.
--
-- Tampoco se puede deducir la pertenencia de quién ha pagado:
--   · alguien puede haber apuntado un gasto en nombre de otra persona;
--   · un grupo sin gastos también necesita miembros y propietario;
--   · se puede pertenecer a un grupo sin haber pagado nunca nada.
--
-- El pagador es una PISTA para preparar la tabla de decisión, nunca la
-- respuesta.
-- ============================================================

-- ------------------------------------------------------------
-- PASO 0 · Este archivo va DESPUÉS de 0002. Si no, no hay dónde escribir.
--
-- El orden de los archivos depende de la configuración regional del sistema:
-- en algunos locales `0002b_` se ordena ANTES que `0002_group_members`, así
-- que un `for f in migrations/*.sql` puede aplicarlos al revés. Esta guarda
-- lo convierte en un error claro en vez de en un fallo confuso.
-- ------------------------------------------------------------
do $$
begin
    if to_regclass('public.group_members') is null then
        raise exception
            'group_members no existe: 0002b se está aplicando ANTES que 0002_group_members'
            using hint = 'Aplica 0002_group_members.sql primero, y los dos en la misma transacción.';
    end if;
end $$;

-- ------------------------------------------------------------
-- PASO 1 · Inventario, solo lectura. Ejecutar y revisar ANTES de rellenar.
--          La consulta está en docs/PLAN-MIGRACION-DATOS.md §3.1; produce una
--          tabla anonimizada (Perfil 1, Perfil 2...) para poder decidir sin
--          exponer correos.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- PASO 2 · Escribir aquí la pertenencia confirmada, grupo por grupo.
--
-- Una línea por persona y grupo. Cada grupo necesita AL MENOS un 'owner'.
-- Si no se puede determinar con seguridad quién creó un grupo histórico,
-- poner a las dos personas como 'owner': es preferible a que el grupo se
-- quede sin nadie que pueda administrarlo.
--
-- Esto es una migración histórica y solo eso. NO es el comportamiento de los
-- grupos futuros: a partir de aquí, crear un grupo mete únicamente a su
-- creador, y todo lo demás va por invitación explícita.
-- ------------------------------------------------------------

-- El `where group_id is not null` deja el archivo como SQL válido mientras
-- siga sin rellenar: la fila de ejemplo no se inserta. Al añadir filas reales
-- descomentándolas, se insertan solas.
insert into public.group_members (group_id, user_id, role)
select group_id, user_id, role
from (values
    -- ('11111111-1111-1111-1111-111111111111'::uuid,  -- grupo
    --  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,  -- persona
    --  'owner'::text),
    -- ('11111111-1111-1111-1111-111111111111'::uuid,
    --  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
    --  'member'::text),
    (null::uuid, null::uuid, null::text)   -- ← fila de ejemplo, no se inserta
) as t(group_id, user_id, role)
where group_id is not null
on conflict do nothing;

-- ------------------------------------------------------------
-- PASO 3 · Comprobaciones. Si alguna falla, la transacción entera se deshace
--          y no queda nada a medias. NO se puede aplicar 0004 (RLS) hasta que
--          las cuatro pasen.
-- ------------------------------------------------------------
do $$
declare
    sin_miembros  text;
    sin_owner     text;
    fuera_gastos  integer;
    fuera_liquid  integer;
begin
    -- 3.1 Ningún grupo puede quedarse sin miembros: sería invisible para todos.
    select string_agg(g.name, ', ') into sin_miembros
    from public.groups g
    where not exists (select 1 from public.group_members m where m.group_id = g.id);

    if sin_miembros is not null then
        raise exception
            'Estos grupos se quedarían sin ningún miembro y desaparecerían para todo el mundo: %',
            sin_miembros
            using hint = 'Completa el PASO 2 de 0002b_backfill_pertenencia.sql.';
    end if;

    -- 3.2 Ningún grupo puede quedarse sin propietario: sería inadministrable.
    select string_agg(g.name, ', ') into sin_owner
    from public.groups g
    where not exists (
        select 1 from public.group_members m
        where m.group_id = g.id and m.role = 'owner'
    );

    if sin_owner is not null then
        raise exception 'Estos grupos se quedarían sin propietario: %', sin_owner;
    end if;

    -- 3.3 Quien ha pagado un gasto tiene que ser miembro de ese grupo, o al
    --     aplicar RLS perdería el acceso a sus propios gastos.
    select count(*) into fuera_gastos
    from public.expenses e
    where not exists (
        select 1 from public.group_members m
        where m.group_id = e.group_id and m.user_id = e.paid_by
    );

    if fuera_gastos > 0 then
        raise exception
            '% gasto(s) tienen un pagador que no es miembro de su grupo', fuera_gastos
            using hint = 'O falta esa persona en el backfill, o el gasto está mal atribuido.';
    end if;

    -- 3.4 Lo mismo para las dos partes de cada liquidación.
    select count(*) into fuera_liquid
    from public.settlements s
    where not exists (
            select 1 from public.group_members m
            where m.group_id = s.group_id and m.user_id = s.from_user)
       or not exists (
            select 1 from public.group_members m
            where m.group_id = s.group_id and m.user_id = s.to_user);

    if fuera_liquid > 0 then
        raise exception
            '% liquidación(es) tienen alguna parte que no es miembro de su grupo', fuera_liquid;
    end if;

    raise notice 'Backfill de pertenencia comprobado: % membresías en % grupos',
        (select count(*) from public.group_members),
        (select count(*) from public.groups);
end $$;
