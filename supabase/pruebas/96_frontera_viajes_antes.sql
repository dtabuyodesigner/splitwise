-- ============================================================
-- Frontera con la aplicación de VIAJES · foto ANTES de migrar
--
-- Esta base de datos la comparten dos aplicaciones. Las migraciones de
-- gastos no deben tocar NADA de `viajes`, `viaje_diario` ni `viaje_fotos`.
-- Aquí se guarda una huella completa de su estado; 97 la vuelve a tomar
-- después de migrar y falla si algo ha cambiado.
--
-- Solo CI, sobre la base desechable.
-- ============================================================

create table if not exists public.frontera_instantanea (
    momento text not null,
    clave   text not null,
    valor   text not null
);

-- Huella de todo lo que define esas tres tablas: columnas, restricciones,
-- índices, políticas, triggers, funciones y pertenencia a Realtime.
create or replace function public.frontera_viajes()
returns table (clave text, valor text)
language sql
stable
as $$
    with tablas as (select unnest(array['viajes','viaje_diario','viaje_fotos']) as t)

    -- Columnas: nombre, tipo, nulabilidad, defecto y posición
    select 'columna',
           c.table_name || '.' || c.column_name || ' :: ' || c.data_type ||
           ' null=' || c.is_nullable ||
           ' def=' || coalesce(c.column_default, '-') ||
           ' pos=' || c.ordinal_position
    from information_schema.columns c
    join tablas on tablas.t = c.table_name
    where c.table_schema = 'public'

    union all
    -- Restricciones, con su definición completa
    select 'restriccion',
           rel.relname || '.' || con.conname || ' = ' || pg_get_constraintdef(con.oid)
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join tablas on tablas.t = rel.relname
    where n.nspname = 'public'

    union all
    -- Índices
    select 'indice', i.tablename || '.' || i.indexname || ' = ' || i.indexdef
    from pg_indexes i
    join tablas on tablas.t = i.tablename
    where i.schemaname = 'public'

    union all
    -- Políticas RLS, con su expresión exacta
    select 'politica',
           p.tablename || '.' || p.policyname ||
           ' cmd=' || p.cmd ||
           ' permissive=' || p.permissive ||
           ' roles=' || p.roles::text ||
           ' using=' || coalesce(p.qual, '-') ||
           ' check=' || coalesce(p.with_check, '-')
    from pg_policies p
    join tablas on tablas.t = p.tablename
    where p.schemaname = 'public'

    union all
    -- ¿RLS activa?
    select 'rls', t.tablename || ' = ' || t.rowsecurity::text
    from pg_tables t
    join tablas on tablas.t = t.tablename
    where t.schemaname = 'public'

    union all
    -- Triggers
    select 'trigger',
           rel.relname || '.' || tg.tgname || ' = ' || pg_get_triggerdef(tg.oid)
    from pg_trigger tg
    join pg_class rel on rel.oid = tg.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join tablas on tablas.t = rel.relname
    where n.nspname = 'public' and not tg.tgisinternal

    union all
    -- La función propia de viajes, con su cuerpo
    select 'funcion', p.proname || ' = ' || pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'viaje%'

    union all
    -- Pertenencia a Realtime
    select 'realtime', pt.tablename
    from pg_publication_tables pt
    join tablas on tablas.t = pt.tablename
    where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'

    union all
    -- Privilegios de tabla concedidos
    select 'privilegio',
           g.table_name || ' ' || g.grantee || ' ' || g.privilege_type
    from information_schema.role_table_grants g
    join tablas on tablas.t = g.table_name
    where g.table_schema = 'public'

    union all
    -- Cuántas filas hay: la migración tampoco debe tocar los datos
    select 'filas', 'viajes = ' || (select count(*)::text from public.viajes)
    union all
    select 'filas', 'viaje_diario = ' || (select count(*)::text from public.viaje_diario)
    union all
    select 'filas', 'viaje_fotos = ' || (select count(*)::text from public.viaje_fotos);
$$;

insert into public.frontera_instantanea (momento, clave, valor)
select 'antes', clave, valor from public.frontera_viajes();

do $$
declare
    n integer;
begin
    select count(*) into n from public.frontera_instantanea where momento = 'antes';
    if n = 0 then
        raise exception 'La foto previa de la frontera de viajes ha salido vacía';
    end if;
    raise notice 'Frontera de viajes: % elementos capturados ANTES de migrar', n;
end $$;
