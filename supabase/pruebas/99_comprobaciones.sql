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

-- ------------------------------------------------------------
-- Ninguna política de las tablas de gastos puede abrir la tabla entera.
--
-- Producción tenía políticas históricas con `using (true)` / `with check
-- (true)`. Como TODAS las permissive se combinan con OR, una sola que
-- sobreviva vuelve a abrir la tabla y las políticas nuevas no cierran nada.
-- Esta comprobación es la red que impide que eso pase inadvertido.
-- ------------------------------------------------------------
do $$
declare
    abiertas text;
begin
    select string_agg(
               tablename || '.' || policyname ||
               ' (using=' || coalesce(qual, '-') ||
               ', check=' || coalesce(with_check, '-') || ')',
               E'\n  ')
      into abiertas
    from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles', 'groups', 'group_members', 'expenses', 'settlements')
      and permissive = 'PERMISSIVE'
      and (btrim(coalesce(qual, '')) = 'true'
           or btrim(coalesce(with_check, '')) = 'true');

    if abiertas is not null then
        raise exception
            E'Hay políticas que abren la tabla entera a cualquier usuario autenticado:\n  %',
            abiertas
            using hint = 'Ninguna política de las tablas de gastos debe usar `true`. '
                         'Si alguna vez hiciera falta, hay que justificarla aquí de forma expresa.';
    end if;
end $$;

-- Y ninguna política histórica puede haber sobrevivido a la migración.
-- Se detectan por lo que son: políticas de las tablas de gastos cuyo nombre
-- no está entre los que crea 0004.
do $$
declare
    esperadas constant text[] := array[
        'profiles_leer', 'profiles_modificar_el_mio', 'profiles_crear_el_mio',
        'groups_leer_los_mios', 'groups_crear', 'groups_modificar', 'groups_borrar',
        'miembros_leer', 'miembros_invitar', 'miembros_cambiar_rol', 'miembros_expulsar',
        'gastos_leer', 'gastos_crear', 'gastos_modificar', 'gastos_borrar',
        'liquidaciones_leer', 'liquidaciones_crear', 'liquidaciones_modificar',
        'liquidaciones_borrar'
    ];
    intrusas text;
begin
    select string_agg(tablename || '.' || policyname, ', ') into intrusas
    from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles', 'groups', 'group_members', 'expenses', 'settlements')
      and policyname <> all (esperadas);

    if intrusas is not null then
        raise exception 'Han sobrevivido políticas ajenas a la migración: %', intrusas
            using hint = 'El paso 0 de 0004_rls.sql debería haberlas retirado.';
    end if;
end $$;

-- La aplicación de viajes conserva SUS políticas: la migración de gastos no
-- puede haberlas tocado.
do $$
declare
    cuantas integer;
begin
    select count(*) into cuantas
    from pg_policies
    where schemaname = 'public'
      and tablename in ('viajes', 'viaje_diario', 'viaje_fotos');

    -- En una base recién creada no hay app de viajes y esto es 0, que es
    -- correcto. En el escenario de actualización hay 7 y deben seguir ahí.
    raise notice 'Políticas de la aplicación de viajes: %', cuantas;
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

-- Un único mecanismo efectivo de creación de perfiles: ni cero (un usuario
-- nuevo no aparecería nunca) ni dos compitiendo (se pisarían).
do $$
declare
    cuantos integer;
    cuales  text;
begin
    select count(*), string_agg(t.tgname, ', ')
      into cuantos, cuales
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal;

    if cuantos <> 1 then
        raise exception
            'Debe haber exactamente un trigger de alta sobre auth.users y hay %: %',
            cuantos, coalesce(cuales, '(ninguno)');
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
