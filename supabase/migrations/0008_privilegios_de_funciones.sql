-- ============================================================
-- 0008 · Cerrar los privilegios de ejecución de las funciones
--
-- Correctiva. 0007 YA está desplegada: esto no la reescribe, la remata.
--
-- El fallo. Supabase deja puestos privilegios POR DEFECTO en el esquema
-- `public` que conceden EXECUTE a `anon`, `authenticated` y `service_role`
-- sobre toda función nueva. Las migraciones anteriores hacían
--
--     revoke all on function ... from public;
--     grant execute on function ... to authenticated;
--
-- y eso NO basta: `PUBLIC` y `anon` son concesiones distintas. Quitar la de
-- PUBLIC deja intacta la directa a `anon`, así que todas las funciones del
-- proyecto —no solo las de 0007— quedaron ejecutables por el rol anónimo.
--
-- Qué se podía hacer con eso, dicho sin adornos: poco. Todas estas funciones
-- cuelgan de `auth.uid()`, que para `anon` es nulo, así que devuelven falso,
-- cero o «No hay sesión», y las de trigger ni siquiera se pueden invocar a
-- mano. No hubo fuga de datos. Pero un privilegio que no debería existir es
-- una trampa esperando a la primera función que dé por hecho que solo la
-- llama alguien con sesión.
--
-- Idempotente. Pensada para --single-transaction.
-- ============================================================

-- ── 1 · Que las funciones nuevas no vuelvan a nacer abiertas ──
-- Sin esto, la próxima función del proyecto repetiría el problema.
alter default privileges in schema public revoke execute on functions from anon;

-- ── 2 · Cerrar TODAS las funciones del esquema, firma por firma ──
-- Se enumera del catálogo en vez de escribir una lista: así se cubren las
-- sobrecargas, las que se añadan después y las que a alguien se le olviden.
do $cerrar$
declare
    f record;
    n integer := 0;
begin
    for f in
        select p.oid,
               p.proname,
               pg_get_function_identity_arguments(p.oid) as args,
               (p.prorettype = 'trigger'::regtype)       as es_trigger
          from pg_proc p
          join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public'
           and p.prokind = 'f'
    loop
        -- PUBLIC y anon fuera, siempre y en todas.
        execute format('revoke all on function public.%I(%s) from public',
                       f.proname, f.args);
        execute format('revoke all on function public.%I(%s) from anon',
                       f.proname, f.args);

        -- Las de trigger no las llama nadie a mano: las invoca el motor al
        -- disparar el trigger, y eso no pasa por este privilegio.
        if f.es_trigger then
            execute format('revoke all on function public.%I(%s) from authenticated',
                           f.proname, f.args);
        end if;

        n := n + 1;
    end loop;
    raise notice 'Privilegios revisados en % función(es) de public', n;
end
$cerrar$;

-- ── 3 · Devolver EXECUTE solo a lo que la aplicación llama ──
-- Lista explícita y corta: si mañana hace falta otra, se añade aquí a mano.
-- Es lo contrario del automatismo de arriba, y a propósito: cerrar conviene
-- que sea exhaustivo, y abrir conviene que sea deliberado.
do $abrir$
declare
    f text;
    firmas text[] := array[
        'public.es_miembro(uuid)',
        'public.es_miembro(uuid, uuid)',
        'public.es_owner(uuid)',
        'public.es_owner(uuid, uuid)',
        'public.puede_viajes()',
        'public.saldo_centimos(uuid, uuid, uuid)',
        'public.pareja_del_grupo(uuid)',
        'public.trasladar_saldo(uuid, uuid, text, numeric)',
        'public.revertir_traslado(uuid)'
    ];
begin
    foreach f in array firmas loop
        if to_regprocedure(f) is not null then
            execute format('grant execute on function %s to authenticated', f);
            raise notice 'EXECUTE para authenticated: %', f;
        end if;
    end loop;
end
$abrir$;

-- ── 4 · Comprobación final ───────────────────────────────────
do $final$
declare
    abiertas text;
    faltan   text;
begin
    -- Ninguna función del esquema puede quedar al alcance de anon o PUBLIC.
    select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
      into abiertas
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.prokind = 'f'
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('public', p.oid, 'execute'));

    if abiertas is not null then
        raise exception 'Siguen siendo ejecutables por anon o PUBLIC: %', abiertas
            using errcode = 'insufficient_privilege';
    end if;

    -- Y las que la aplicación necesita tienen que seguir funcionando.
    select string_agg(f, ', ') into faltan from (
        select unnest(array[
            'public.es_miembro(uuid)',
            'public.trasladar_saldo(uuid, uuid, text, numeric)',
            'public.revertir_traslado(uuid)'
        ]) as f
    ) t
     where to_regprocedure(t.f) is not null
       and not has_function_privilege('authenticated', t.f, 'execute');

    if faltan is not null then
        raise exception 'authenticated ha perdido EXECUTE sobre: %', faltan;
    end if;

    raise notice 'Funciones cerradas: ni anon ni PUBLIC pueden ejecutar ninguna, y authenticated conserva las suyas';
end
$final$;
