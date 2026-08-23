-- ============================================================
-- Comprueba que el escenario histórico reproduce DE VERDAD el problema.
--
-- Si aquí no hay políticas abiertas, el escenario no vale: la prueba de
-- actualización pasaría sin demostrar nada.
-- ============================================================
\set ON_ERROR_STOP on

do $$
declare
    abiertas integer;
    trigger_alta text;
begin
    select count(*) into abiertas
    from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles', 'groups', 'expenses', 'settlements')
      and (btrim(coalesce(qual, '')) = 'true' or btrim(coalesce(with_check, '')) = 'true');

    if abiertas = 0 then
        raise exception
            'El escenario histórico no tiene ninguna política abierta: no probaría nada';
    end if;

    -- Y el trigger de alta que ya existe en producción tiene que estar.
    select string_agg(t.tgname, ', ') into trigger_alta
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal;

    if trigger_alta is null then
        raise exception 'El escenario histórico debería tener el trigger de alta ya existente';
    end if;

    -- Y group_members NO debe existir todavía: es lo que añade la migración.
    if to_regclass('public.group_members') is not null then
        raise exception 'El escenario histórico no debería tener group_members';
    end if;

    raise notice 'Punto de partida correcto: % políticas abiertas, trigger de alta "%", sin group_members',
        abiertas, trigger_alta;
end $$;
