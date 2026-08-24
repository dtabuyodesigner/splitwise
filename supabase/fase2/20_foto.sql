-- ============================================================
-- Fotografía de la copia · SOLO LECTURA sobre los datos
--
--     psql "$URL_COPIA" -v momento=antes   -f supabase/fase2/20_foto.sql
--     psql "$URL_COPIA" -v momento=despues -f supabase/fase2/20_foto.sql
--
-- Guarda una huella de todo lo que la migración NO debe romper. Las filas
-- que guarda son RECUENTOS y METADATOS: ni correos, ni UUID, ni conceptos,
-- ni notas, ni importes individuales.
-- ============================================================
\set ON_ERROR_STOP on

create table if not exists public.foto_validacion (
    momento text not null,
    ambito  text not null,
    clave   text not null,
    valor   text not null
);

-- ── Contar una tabla que puede no existir todavía ──────────────
-- `tomar_foto()` es `language sql`, y PostgreSQL analiza el cuerpo entero al
-- crear la función: una referencia literal a `public.group_members` hace
-- fallar el CREATE FUNCTION con «no existe la relación» cuando la tabla aún
-- no está, que es justo el estado que hay que fotografiar ANTES de migrar.
--
-- Esta auxiliar recibe el OID ya resuelto (o NULL) y solo ejecuta el count
-- dinámicamente si la tabla existe. Ni crea tablas ficticias, ni captura
-- excepciones: no hay nada que ocultar, solo un NULL que comprobar.
create or replace function public.contar_si_existe(rel regclass)
returns text
language plpgsql
stable
as $contar$
declare
    filas bigint;
begin
    if rel is null then
        return 'TABLA-AUSENTE';
    end if;
    execute format('select count(*) from %s', rel) into filas;
    return filas::text;
end
$contar$;

create or replace function public.tomar_foto()
returns table (ambito text, clave text, valor text)
language sql
stable
as $$
    -- ── Gastos: cuántas filas hay de cada cosa ──
    select 'recuento', 'profiles',    count(*)::text from public.profiles
    union all
    select 'recuento', 'groups',      count(*)::text from public.groups
    union all
    select 'recuento', 'expenses',    count(*)::text from public.expenses
    union all
    select 'recuento', 'settlements', count(*)::text from public.settlements
    union all
    select 'recuento', 'auth.users',  count(*)::text from auth.users
    union all
    select 'recuento', 'group_members',
           public.contar_si_existe(to_regclass('public.group_members'))

    union all
    -- ── Los grupos, por nombre. El nombre hace falta: el backfill lo exige ──
    select 'grupo', g.name,
           (select count(*)::text from public.expenses e where e.group_id = g.id)
           || ' gastos, '
           || (select count(*)::text from public.settlements s where s.group_id = g.id)
           || ' liquidaciones'
    from public.groups g

    union all
    -- ── Perfiles, identificados por color (nunca por nombre ni correo) ──
    select 'perfil', p.color,
           (select count(*)::text from public.expenses e where e.paid_by = p.id) || ' gastos pagados'
    from public.profiles p

    union all
    -- ── Integridad referencial ──
    select 'integridad', 'gastos con pagador desconocido',
           (select count(*)::text from public.expenses e
            where not exists (select 1 from public.profiles p where p.id = e.paid_by))
    union all
    select 'integridad', 'gastos sin grupo',
           (select count(*)::text from public.expenses e
            where not exists (select 1 from public.groups g where g.id = e.group_id))
    union all
    select 'integridad', 'liquidaciones con parte desconocida',
           (select count(*)::text from public.settlements s
            where not exists (select 1 from public.profiles p where p.id = s.from_user)
               or not exists (select 1 from public.profiles p where p.id = s.to_user))
    union all
    select 'integridad', 'client_id duplicados en expenses',
           (select count(*)::text from (
                select client_id from public.expenses
                where client_id is not null group by client_id having count(*) > 1) d)
    union all
    select 'integridad', 'client_id duplicados en settlements',
           (select count(*)::text from (
                select client_id from public.settlements
                where client_id is not null group by client_id having count(*) > 1) d)

    union all
    -- ── Políticas RLS de las tablas de gastos ──
    select 'politica', p.tablename || '.' || p.policyname,
           p.cmd || ' | using=' || coalesce(p.qual, '-') ||
           ' | check=' || coalesce(p.with_check, '-')
    from pg_policies p
    where p.schemaname = 'public'
      and p.tablename in ('profiles','groups','group_members','expenses','settlements')

    union all
    select 'rls', t.tablename, t.rowsecurity::text
    from pg_tables t
    where t.schemaname = 'public'
      and t.tablename in ('profiles','groups','group_members','expenses','settlements')

    union all
    -- ── Realtime: qué tablas de gastos están publicadas ──
    -- Aparte de `viajes:realtime`, que es frontera de la otra aplicación.
    -- `pg_dump --schema` no trae las publicaciones, así que en una copia esto
    -- solo tiene valor si la publicación se ha reconstruido a mano antes.
    select 'realtime', pt.tablename, pt.pubname
    from pg_publication_tables pt
    where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
      and pt.tablename in ('profiles','groups','group_members','expenses','settlements')

    union all
    -- ── Mecanismo de alta de perfiles ──
    select 'alta', tg.tgname, p.proname || '() en ' || n.nspname
    from pg_trigger tg
    join pg_class rel on rel.oid = tg.tgrelid
    join pg_namespace rn on rn.oid = rel.relnamespace
    join pg_proc p on p.oid = tg.tgfoid
    join pg_namespace n on n.oid = p.pronamespace
    where rn.nspname = 'auth' and rel.relname = 'users' and not tg.tgisinternal

    union all
    -- ── La aplicación de VIAJES: nada de esto puede cambiar ──
    select 'viajes:columna',
           c.table_name || '.' || c.column_name,
           c.data_type || ' null=' || c.is_nullable || ' def=' || coalesce(c.column_default, '-')
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name in ('viajes','viaje_diario','viaje_fotos')
    union all
    select 'viajes:restriccion', rel.relname || '.' || con.conname, pg_get_constraintdef(con.oid)
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'public' and rel.relname in ('viajes','viaje_diario','viaje_fotos')
    union all
    select 'viajes:indice', i.tablename || '.' || i.indexname, i.indexdef
    from pg_indexes i
    where i.schemaname = 'public' and i.tablename in ('viajes','viaje_diario','viaje_fotos')
    union all
    select 'viajes:politica', p.tablename || '.' || p.policyname,
           p.cmd || ' | using=' || coalesce(p.qual, '-') || ' | check=' || coalesce(p.with_check, '-')
    from pg_policies p
    where p.schemaname = 'public' and p.tablename in ('viajes','viaje_diario','viaje_fotos')
    union all
    select 'viajes:trigger', rel.relname || '.' || tg.tgname, pg_get_triggerdef(tg.oid)
    from pg_trigger tg
    join pg_class rel on rel.oid = tg.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'public' and rel.relname in ('viajes','viaje_diario','viaje_fotos')
      and not tg.tgisinternal
    union all
    select 'viajes:funcion', p.proname, pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'viaje%'
    union all
    select 'viajes:privilegio', g.table_name || ' ' || g.grantee, g.privilege_type
    from information_schema.role_table_grants g
    where g.table_schema = 'public' and g.table_name in ('viajes','viaje_diario','viaje_fotos')
    union all
    select 'viajes:realtime', pt.tablename, 'publicada'
    from pg_publication_tables pt
    where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
      and pt.tablename in ('viajes','viaje_diario','viaje_fotos')
    union all
    select 'viajes:filas', t.relname,
           (case t.relname
                when 'viajes'       then (select count(*) from public.viajes)
                when 'viaje_diario' then (select count(*) from public.viaje_diario)
                when 'viaje_fotos'  then (select count(*) from public.viaje_fotos)
            end)::text
    from (values ('viajes'),('viaje_diario'),('viaje_fotos')) as t(relname)
    where to_regclass('public.' || t.relname) is not null;
$$;

delete from public.foto_validacion where momento = :'momento';

insert into public.foto_validacion (momento, ambito, clave, valor)
select :'momento', ambito, clave, valor from public.tomar_foto();

select :'momento' as momento, count(*) as elementos_capturados
from public.foto_validacion where momento = :'momento';
