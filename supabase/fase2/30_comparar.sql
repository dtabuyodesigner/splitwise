-- ============================================================
-- Comparación ANTES / DESPUÉS sobre la copia
--
--     psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/fase2/30_comparar.sql
--
-- Falla si la migración ha roto algo que debía quedar intacto, o si no ha
-- conseguido lo que debía conseguir. No imprime ningún dato personal.
-- ============================================================
\set ON_ERROR_STOP on

-- ── 1 · Nada de la aplicación de VIAJES puede haber cambiado ──
do $$
declare
    perdido  text;
    aparecido text;
begin
    select string_agg(ambito || ' · ' || clave, E'\n  ') into perdido
    from (
        select ambito, clave, valor from public.foto_validacion
         where momento = 'antes' and ambito like 'viajes:%'
        except all
        select ambito, clave, valor from public.foto_validacion
         where momento = 'despues' and ambito like 'viajes:%'
    ) d;

    select string_agg(ambito || ' · ' || clave, E'\n  ') into aparecido
    from (
        select ambito, clave, valor from public.foto_validacion
         where momento = 'despues' and ambito like 'viajes:%'
        except all
        select ambito, clave, valor from public.foto_validacion
         where momento = 'antes' and ambito like 'viajes:%'
    ) d;

    if perdido is not null then
        raise exception E'La migración ha DESTRUIDO algo de la app de viajes:\n  %', perdido;
    end if;
    if aparecido is not null then
        raise exception E'La migración ha AÑADIDO algo a la app de viajes:\n  %', aparecido;
    end if;

    raise notice '[C1] ok — la aplicación de viajes está intacta (% elementos)',
        (select count(*) from public.foto_validacion
          where momento = 'antes' and ambito like 'viajes:%');
end $$;

-- ── 2 · No se pierde ni se altera ningún dato histórico ──
do $$
declare
    fila record;
begin
    for fila in
        select a.clave, a.valor as antes, d.valor as despues
        from public.foto_validacion a
        join public.foto_validacion d
          on d.momento = 'despues' and d.ambito = a.ambito and d.clave = a.clave
        where a.momento = 'antes'
          and a.ambito = 'recuento'
          and a.clave in ('profiles','groups','expenses','settlements','auth.users')
    loop
        if fila.antes is distinct from fila.despues then
            raise exception
                'El recuento de % ha cambiado: % antes, % después',
                fila.clave, fila.antes, fila.despues;
        end if;
    end loop;
    raise notice '[C2] ok — perfiles, grupos, gastos y liquidaciones: mismos recuentos';
end $$;

-- ── 3 · Los grupos siguen siendo los mismos, con los mismos movimientos ──
do $$
declare
    distinto text;
begin
    select string_agg(clave, ', ') into distinto
    from (
        select clave, valor from public.foto_validacion
         where momento = 'antes' and ambito = 'grupo'
        except
        select clave, valor from public.foto_validacion
         where momento = 'despues' and ambito = 'grupo'
    ) d;

    if distinto is not null then
        raise exception 'Estos grupos han cambiado de contenido: %', distinto;
    end if;
    raise notice '[C3] ok — los grupos conservan nombre y número de movimientos';
end $$;

-- ── 4 · group_members: ausente antes, con la pertenencia decidida después ──
do $$
declare
    antes    text;
    despues  text;
    mal      text;
begin
    select valor into antes   from public.foto_validacion
     where momento = 'antes'   and ambito = 'recuento' and clave = 'group_members';
    select valor into despues from public.foto_validacion
     where momento = 'despues' and ambito = 'recuento' and clave = 'group_members';

    if antes <> 'TABLA-AUSENTE' then
        raise exception 'group_members ya existía antes de migrar (valor: %)', antes;
    end if;

    if despues <> '6' then
        raise exception 'Tras migrar debería haber 6 membresías y hay %', despues;
    end if;

    -- Y cada grupo con los dos perfiles, los dos propietarios.
    select string_agg(g.name || ' (' || x.miembros || '/' || x.owners || ')', '; ')
      into mal
    from public.groups g
    cross join lateral (
        select count(*) as miembros, count(*) filter (where m.role = 'owner') as owners
        from public.group_members m where m.group_id = g.id
    ) x
    where x.miembros <> 2 or x.owners <> 2;

    if mal is not null then
        raise exception 'Grupos sin los dos perfiles como propietarios: %', mal;
    end if;

    raise notice '[C4] ok — group_members no existía antes; después: 6 membresías, los 3 grupos con 2 propietarios';
end $$;

-- ── 5 · Cada pagador y cada parte de liquidación pertenece a su grupo ──
do $$
declare
    g integer; l integer;
begin
    select count(*) into g from public.expenses e
     where not exists (select 1 from public.group_members m
                       where m.group_id = e.group_id and m.user_id = e.paid_by);
    select count(*) into l from public.settlements s
     where not exists (select 1 from public.group_members m
                       where m.group_id = s.group_id and m.user_id = s.from_user)
        or not exists (select 1 from public.group_members m
                       where m.group_id = s.group_id and m.user_id = s.to_user);

    if g > 0 or l > 0 then
        raise exception
            'Tras migrar hay % gasto(s) y % liquidación(es) con alguien que no pertenece a su grupo',
            g, l;
    end if;
    raise notice '[C5] ok — todo pagador y toda parte de liquidación pertenece a su grupo';
end $$;

-- ── 6 · Las políticas antiguas han desaparecido y no queda ninguna abierta ──
do $$
declare
    viejas   text;
    abiertas text;
begin
    select string_agg(clave, ', ') into viejas
    from (
        select clave from public.foto_validacion
         where momento = 'antes' and ambito = 'politica'
        intersect
        select clave from public.foto_validacion
         where momento = 'despues' and ambito = 'politica'
    ) d;

    if viejas is not null then
        raise exception 'Han sobrevivido políticas anteriores a la migración: %', viejas;
    end if;

    select string_agg(tablename || '.' || policyname, ', ') into abiertas
    from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles','groups','group_members','expenses','settlements')
      and permissive = 'PERMISSIVE'
      and (btrim(coalesce(qual, '')) = 'true' or btrim(coalesce(with_check, '')) = 'true');

    if abiertas is not null then
        raise exception 'Quedan políticas que abren la tabla entera: %', abiertas;
    end if;

    raise notice '[C6] ok — ninguna política anterior ha sobrevivido y ninguna usa `true`';
end $$;

-- ── 7 · Sigue habiendo un único mecanismo de alta de perfiles ──
do $$
declare
    cuantos integer;
begin
    select count(*) into cuantos
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace fn on fn.oid = p.pronamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal
      and fn.nspname = 'public' and p.proname = 'handle_new_user' and p.pronargs = 0;

    if cuantos <> 1 then
        raise exception 'Debe haber un único mecanismo de alta de perfiles y hay %', cuantos;
    end if;
    raise notice '[C7] ok — un único mecanismo de alta de perfiles';
end $$;

select 'Comparación antes/después superada' as resultado;
