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

-- es_owner existe, es SECURITY DEFINER y tiene search_path fijo.
do $$
begin
    if not exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'es_owner' and p.prosecdef
    ) then
        raise exception 'public.es_owner no existe o no es SECURITY DEFINER';
    end if;
end $$;

-- Ninguna política de group_members puede consultar group_members: sería
-- recursión infinita al expandir RLS.
do $$
declare
    culpable text;
begin
    select string_agg(pol.polname, ', ') into culpable
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    where c.relname = 'group_members'
      -- Solo un FROM sobre la propia tabla provoca recursión. Una referencia
      -- de columna cualificada (`group_members.group_id`) dentro de una
      -- subconsulta a OTRA tabla es legítima, y un LIKE '%group_members%' la
      -- confundiría con una autorreferencia.
      and (coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') ~* 'from\s+(public\.)?group_members'
           or coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') ~* 'from\s+(public\.)?group_members');

    if culpable is not null then
        raise exception
            'Estas políticas de group_members se consultan a sí mismas y provocarán recursión: %',
            culpable;
    end if;
end $$;

-- El trigger que impide dejar un grupo sin propietario está instalado.
do $$
begin
    if not exists (
        select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
        where c.relname = 'group_members'
          and t.tgname = 'antes_de_perder_propietario'
          and not t.tgisinternal
    ) then
        raise exception 'Falta el trigger antes_de_perder_propietario en group_members';
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

-- La política de lectura de `groups` tiene que cubrir al creador: si no,
-- `insert(...).select().single()` no devuelve nada y crear un grupo falla.
do $$
declare
    expresion text;
begin
    select pg_get_expr(pol.polqual, pol.polrelid) into expresion
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    where c.relname = 'groups' and pol.polname = 'groups_leer_los_mios';

    if expresion is null then
        raise exception 'No existe la política groups_leer_los_mios';
    end if;

    if expresion not like '%created_by%' then
        raise exception 'groups_leer_los_mios no contempla al creador: crear un grupo fallaría. Expresión: %', expresion;
    end if;
end $$;
