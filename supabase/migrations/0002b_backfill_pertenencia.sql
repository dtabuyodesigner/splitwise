-- ============================================================
-- 0002b · Backfill de la pertenencia a los grupos existentes
--
-- NO APLICADO todavía a producción.
--
-- Se aplica SIEMPRE en la misma transacción que 0002:
--
--     psql "$URL" -v ON_ERROR_STOP=1 --single-transaction \
--       -f supabase/migrations/0002_group_members.sql \
--       -f supabase/migrations/0002b_backfill_pertenencia.sql
--
-- ------------------------------------------------------------
-- DECISIÓN DE DANI, confirmada tras el inventario de solo lectura
--
--   Casa               → Dani y Pilar, los dos propietarios
--   Slovenia           → Dani y Pilar, los dos propietarios
--   Bierzo & Asturias  → Dani y Pilar, los dos propietarios
--
-- Los dos como propietarios porque `groups.created_by` no existía antes de
-- 0001: no hay forma de saber quién creó cada grupo, y es preferible eso a
-- que un grupo se quede sin nadie que pueda administrarlo.
--
-- **Esto es una migración histórica y solo eso.** No es el comportamiento de
-- los grupos futuros: a partir de aquí, crear un grupo mete únicamente a su
-- creador, y todo lo demás va por invitación explícita.
--
-- ------------------------------------------------------------
-- CÓMO SE IDENTIFICA A CADA PERSONA SIN METER DATOS PERSONALES
--
-- Este archivo NO contiene UUID ni correos. Los perfiles se resuelven por su
-- `color`, que es determinista y está verificado en el inventario:
--
--   laurel     → Dani
--   buganvilla → Pilar
--
-- Y se comprueba, además, que el perfil `laurel` es el más antiguo, que es
-- lo que decía el inventario ("Perfil 1 = Dani, laurel"). Si esas dos vías
-- no coincidieran, la migración aborta en lugar de elegir una.
--
-- ------------------------------------------------------------
-- TODO O NADA
--
-- El archivo entero está pensado para deshacerse solo. Si cualquiera de las
-- guardas falla, la excepción revierte la transacción completa y no queda
-- ninguna membresía a medias. Las guardas están ANTES y DESPUÉS del insert.
-- ============================================================

do $$
declare
    -- Grupos históricos con decisión tomada. Cualquier otro aborta.
    grupos_esperados constant text[] := array['Casa', 'Slovenia', 'Bierzo & Asturias'];

    n_perfiles   integer;
    n_grupos     integer;
    n_laurel     integer;
    n_buganvilla integer;
    id_dani      uuid;
    id_pilar     uuid;
    id_mas_antiguo uuid;
    sobrantes    text;
    faltantes    text;
    insertadas   integer;
begin
    -- ------------------------------------------------------------
    -- 0 · ¿Hay historia que migrar?
    --
    -- En una instalación limpia no hay ningún grupo, así que no hay nada que
    -- rellenar y este archivo no debe hacer nada. Es el único caso en el que
    -- se sale sin tocar nada; con un solo grupo ya se exige que la realidad
    -- sea exactamente la esperada.
    -- ------------------------------------------------------------
    select count(*) into n_grupos from public.groups;

    if n_grupos = 0 then
        raise notice 'No hay ningún grupo: instalación limpia, nada que migrar.';
        return;
    end if;

    -- ------------------------------------------------------------
    -- 1 · Exactamente dos perfiles históricos
    -- ------------------------------------------------------------
    select count(*) into n_perfiles from public.profiles;

    if n_perfiles <> 2 then
        raise exception
            'Se esperaban exactamente 2 perfiles históricos y hay %', n_perfiles
            using hint = 'Este backfill solo describe la situación de Dani y Pilar. '
                         'Con otro número de perfiles hay que decidir de nuevo la pertenencia.';
    end if;

    -- ------------------------------------------------------------
    -- 2 · Dani y Pilar identificables sin ambigüedad
    -- ------------------------------------------------------------
    select count(*) filter (where color = 'laurel'),
           count(*) filter (where color = 'buganvilla')
      into n_laurel, n_buganvilla
    from public.profiles;

    if n_laurel <> 1 or n_buganvilla <> 1 then
        raise exception
            'No se puede identificar a Dani y Pilar por color: % laurel, % buganvilla',
            n_laurel, n_buganvilla
            using hint = 'Se esperaba exactamente un perfil laurel (Dani) y uno buganvilla (Pilar).';
    end if;

    select id into id_dani  from public.profiles where color = 'laurel';
    select id into id_pilar from public.profiles where color = 'buganvilla';

    if id_dani is null or id_pilar is null or id_dani = id_pilar then
        raise exception 'La resolución de perfiles por color no ha dado dos personas distintas';
    end if;

    -- Segunda vía independiente: el inventario decía que Dani es el perfil
    -- más antiguo. Si el color y la antigüedad no coinciden, algo ha
    -- cambiado desde el inventario y no se elige por nuestra cuenta.
    select id into id_mas_antiguo
    from public.profiles order by created_at, id limit 1;

    if id_mas_antiguo <> id_dani then
        raise exception
            'El perfil laurel no es el más antiguo: el color y la antigüedad no coinciden'
            using hint = 'El inventario decía "Perfil 1 = Dani, laurel". Vuelve a inventariar '
                         'antes de aplicar este backfill.';
    end if;

    -- ------------------------------------------------------------
    -- 3 · Exactamente los tres grupos con decisión tomada
    -- ------------------------------------------------------------
    select string_agg(g.name, ', ' order by g.name) into sobrantes
    from public.groups g
    where g.name <> all (grupos_esperados);

    if sobrantes is not null then
        raise exception
            'Hay grupos históricos sin decisión de pertenencia: %', sobrantes
            using hint = 'Dani tiene que decidir quién pertenece a cada uno antes de migrar.';
    end if;

    select string_agg(esperado, ', ' order by esperado) into faltantes
    from unnest(grupos_esperados) as esperado
    where not exists (select 1 from public.groups g where g.name = esperado);

    if faltantes is not null then
        raise exception
            'No están los grupos históricos que se esperaban: faltan %', faltantes;
    end if;

    if n_grupos <> array_length(grupos_esperados, 1) then
        raise exception
            'Se esperaban % grupos y hay % (¿nombres repetidos?)',
            array_length(grupos_esperados, 1), n_grupos;
    end if;

    -- ------------------------------------------------------------
    -- 4 · El insert, acotado por todo lo anterior
    --
    -- Es un producto de 3 grupos × 2 personas, pero NO es el `cross join
    -- profiles` genérico que se retiró: aquí los dos perfiles están
    -- verificados uno a uno, los tres grupos están comprobados por nombre, y
    -- cualquier desviación ya habría abortado más arriba.
    --
    -- `on conflict do nothing` lo hace repetible: una segunda ejecución no
    -- inserta nada y no cambia ningún rol.
    -- ------------------------------------------------------------
    insert into public.group_members (group_id, user_id, role)
    select g.id, quien.id, 'owner'
    from public.groups g
    cross join (values (id_dani), (id_pilar)) as quien(id)
    where g.name = any (grupos_esperados)
    on conflict (group_id, user_id) do nothing;

    get diagnostics insertadas = row_count;
    raise notice 'Backfill: % membresías insertadas', insertadas;
end $$;

-- ============================================================
-- COMPROBACIONES POSTERIORES
--
-- Van fuera del bloque anterior, para que se ejecuten también cuando el
-- backfill no ha insertado nada por ser una segunda pasada.
-- ============================================================
do $$
declare
    grupos_esperados constant text[] := array['Casa', 'Slovenia', 'Bierzo & Asturias'];
    sin_miembros  text;
    sin_owner     text;
    mal_formados  text;
    fuera_gastos  integer;
    fuera_liquid  integer;
    total         integer;
begin
    if (select count(*) from public.groups) = 0 then
        return;   -- instalación limpia
    end if;

    -- 5 · Ningún grupo sin miembros: sería invisible para todo el mundo.
    select string_agg(g.name, ', ') into sin_miembros
    from public.groups g
    where not exists (select 1 from public.group_members m where m.group_id = g.id);

    if sin_miembros is not null then
        raise exception 'Estos grupos se quedarían sin ningún miembro: %', sin_miembros;
    end if;

    -- 6 · Ningún grupo sin propietario: sería inadministrable.
    select string_agg(g.name, ', ') into sin_owner
    from public.groups g
    where not exists (select 1 from public.group_members m
                      where m.group_id = g.id and m.role = 'owner');

    if sin_owner is not null then
        raise exception 'Estos grupos se quedarían sin propietario: %', sin_owner;
    end if;

    -- 7 · Quien pagó un gasto pertenece a su grupo, o perdería el acceso a
    --     sus propios gastos al activar RLS.
    select count(*) into fuera_gastos
    from public.expenses e
    where not exists (select 1 from public.group_members m
                      where m.group_id = e.group_id and m.user_id = e.paid_by);

    if fuera_gastos > 0 then
        raise exception '% gasto(s) tienen un pagador que no es miembro de su grupo', fuera_gastos;
    end if;

    -- 8 · Lo mismo para las dos partes de cada liquidación.
    select count(*) into fuera_liquid
    from public.settlements s
    where not exists (select 1 from public.group_members m
                      where m.group_id = s.group_id and m.user_id = s.from_user)
       or not exists (select 1 from public.group_members m
                      where m.group_id = s.group_id and m.user_id = s.to_user);

    if fuera_liquid > 0 then
        raise exception '% liquidación(es) tienen alguna parte que no es miembro de su grupo', fuera_liquid;
    end if;

    -- 9 · El resultado es EXACTAMENTE el decidido: en cada uno de los tres
    --     grupos, los dos perfiles, los dos como propietarios. Ni más ni menos.
    select string_agg(g.name || ' (' || x.miembros || ' miembros, ' || x.owners || ' owners)', '; ')
      into mal_formados
    from public.groups g
    cross join lateral (
        select count(*) as miembros,
               count(*) filter (where m.role = 'owner') as owners
        from public.group_members m where m.group_id = g.id
    ) x
    where x.miembros <> 2 or x.owners <> 2;

    if mal_formados is not null then
        raise exception
            'Algún grupo no ha quedado con los dos perfiles como propietarios: %', mal_formados;
    end if;

    -- 10 · Y el total cuadra: 3 grupos × 2 personas. Detecta duplicados y
    --      cualquier fila de más que se hubiera colado.
    select count(*) into total from public.group_members;

    if total <> array_length(grupos_esperados, 1) * 2 then
        raise exception
            'group_members debería tener % filas y tiene %',
            array_length(grupos_esperados, 1) * 2, total;
    end if;

    raise notice
        'Backfill comprobado: % membresías, los 3 grupos con 2 miembros y 2 propietarios cada uno',
        total;
end $$;
