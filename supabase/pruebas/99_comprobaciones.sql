-- ============================================================
-- Comprobaciones posteriores a aplicar las migraciones.
-- Se ejecutan en CI sobre la base desechable. Cada consulta debe devolver
-- el valor esperado; si no, psql sale con error por el \if.
-- ============================================================
\set ON_ERROR_STOP on

-- RLS activa en las cinco tablas
do $$
declare
    sin_rls text;
begin
    select string_agg(tablename, ', ') into sin_rls
    from pg_tables
    where schemaname = 'public'
      and tablename in ('profiles', 'groups', 'group_members', 'expenses', 'settlements')
      and not rowsecurity;

    if sin_rls is not null then
        raise exception 'Estas tablas se han quedado sin RLS: %', sin_rls;
    end if;
end $$;

-- Ninguna tabla con RLS activa y cero políticas: eso las dejaría en blanco.
do $$
declare
    huerfana text;
begin
    select string_agg(t.tablename, ', ') into huerfana
    from pg_tables t
    where t.schemaname = 'public'
      and t.rowsecurity
      and not exists (
          select 1 from pg_policies p
          where p.schemaname = 'public' and p.tablename = t.tablename
      );

    if huerfana is not null then
        raise exception 'Tablas con RLS y sin ninguna política: %', huerfana;
    end if;
end $$;

-- El índice único de client_id existe: sin él, la cola offline duplica gastos.
do $$
begin
    if not exists (select 1 from pg_indexes
                   where schemaname = 'public' and indexname = 'uq_expenses_client_id') then
        raise exception 'Falta uq_expenses_client_id';
    end if;
    if not exists (select 1 from pg_indexes
                   where schemaname = 'public' and indexname = 'uq_settlements_client_id') then
        raise exception 'Falta uq_settlements_client_id';
    end if;
end $$;

-- La función de pertenencia existe y es SECURITY DEFINER (si no, recursión).
do $$
begin
    if not exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'es_miembro' and p.prosecdef
    ) then
        raise exception 'public.es_miembro no existe o no es SECURITY DEFINER';
    end if;
end $$;

-- Realtime publica las tablas que la app escucha.
do $$
declare
    falta text;
begin
    select string_agg(t, ', ') into falta
    from unnest(array['expenses', 'settlements', 'groups', 'profiles']) as t
    where not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    );

    if falta is not null then
        raise exception 'Realtime no publica: %', falta;
    end if;
end $$;

select 'Todas las comprobaciones del esquema han pasado' as resultado;
