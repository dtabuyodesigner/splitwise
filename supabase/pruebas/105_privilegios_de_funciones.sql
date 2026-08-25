-- ============================================================
-- Privilegios de ejecución · DML real
--
-- Se ejecuta DESPUÉS de 0008. Comprueba las dos mitades del asunto:
--
--   · que `anon` y PUBLIC no pueden ejecutar NADA, y que cuando lo intentan
--     fallan por FALTA DE PRIVILEGIO y no por una validación interna de la
--     función —que es lo que distingue una puerta cerrada de una puerta
--     abierta que resulta que no lleva a ningún sitio—;
--   · que cerrar no ha roto la aplicación: los triggers siguen disparando y
--     quien tiene sesión sigue llegando a la lógica.
-- ============================================================
\set ON_ERROR_STOP on

begin;

create temporary table pr (etiqueta text primary key) on commit drop;
create or replace function pg_temp.ok(p_et text, p_txt text)
returns void language plpgsql as $$
begin
    insert into pr values (p_et);
    raise notice '[%] ok — %', p_et, p_txt;
end $$;
grant insert, select on pr to authenticated, anon;
grant execute on function pg_temp.ok(text, text) to authenticated, anon;

-- ── Ninguna función del esquema queda expuesta ───────────────
do $$
declare abiertas text;
begin
    select string_agg(p.proname, ', ') into abiertas
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.prokind = 'f'
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('public', p.oid, 'execute'));
    if abiertas is not null then
        raise exception '[P1] FALLA — ejecutables por anon o PUBLIC: %', abiertas;
    end if;
    perform pg_temp.ok('P1', 'ninguna función de public es ejecutable por anon ni por PUBLIC');

    -- Incluidas las sobrecargas: se cuenta por oid, no por nombre.
    if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                where ns.nspname='public' and p.prokind='f'
                  and p.proname in ('trasladar_saldo','revertir_traslado')
                  and has_function_privilege('anon', p.oid, 'execute')) then
        raise exception '[P2] FALLA — alguna sobrecarga sigue expuesta a anon';
    end if;
    perform pg_temp.ok('P2', 'ninguna sobrecarga de las RPC del traslado queda expuesta');

    -- Y los privilegios por defecto no vuelven a abrirlas.
    if exists (select 1 from pg_default_acl d
                left join pg_namespace n on n.oid = d.defaclnamespace
                join aclexplode(d.defaclacl) a on true
                join pg_roles r on r.oid = a.grantee
               where d.defaclobjtype = 'f' and n.nspname = 'public'
                 and r.rolname = 'anon' and a.privilege_type = 'EXECUTE') then
        raise exception '[P3] FALLA — los privilegios por defecto siguen dando EXECUTE a anon';
    end if;
    perform pg_temp.ok('P3', 'las funciones nuevas ya no nacerán abiertas a anon');
end $$;

-- ── anon: la puerta está cerrada, y falla por eso ────────────
set local role anon;
do $$
begin
    begin
        perform public.trasladar_saldo(gen_random_uuid(), gen_random_uuid(), 'anon-1');
        raise exception '[P4] FALLA — anon ha podido invocar trasladar_saldo';
    exception when insufficient_privilege then
        -- Esto es lo que importa: 42501, no «No hay sesión». Si fallara por
        -- la validación interna, la función SEGUIRÍA siendo ejecutable.
        if sqlerrm not ilike '%permis%' and sqlerrm not ilike '%denied%' then
            raise exception '[P4] FALLA — falló por «%», no por falta de privilegio', sqlerrm;
        end if;
        perform pg_temp.ok('P4', 'anon no puede invocar trasladar_saldo: falta de privilegio, no validación interna');
    end;

    begin
        perform public.revertir_traslado(gen_random_uuid());
        raise exception '[P5] FALLA — anon ha podido invocar revertir_traslado';
    exception when insufficient_privilege then
        perform pg_temp.ok('P5', 'anon no puede invocar revertir_traslado');
    end;

    begin
        perform public.puede_viajes();
        raise exception '[P6] FALLA — anon ha podido invocar puede_viajes';
    exception when insufficient_privilege then
        perform pg_temp.ok('P6', 'anon no puede invocar puede_viajes');
    end;

    begin
        perform public.es_miembro(gen_random_uuid());
        raise exception '[P7] FALLA — anon ha podido invocar es_miembro';
    exception when insufficient_privilege then
        perform pg_temp.ok('P7', 'anon no puede invocar es_miembro');
    end;
end $$;
reset role;

-- ── authenticated: sigue llegando a la lógica ────────────────
do $$
declare quien uuid;
begin
    select id into quien from public.profiles order by created_at, id limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', quien)::text, true);
end $$;
set local role authenticated;

do $$
declare g uuid; n bigint;
begin
    -- Que NO falle por privilegio es justo lo contrario de lo de arriba.
    select group_id into g from public.group_members limit 1;
    perform public.es_miembro(g);
    perform public.puede_viajes();
    perform public.pareja_del_grupo(g);
    perform public.saldo_centimos(g, (public.pareja_del_grupo(g))[1],
                                     (public.pareja_del_grupo(g))[2]);
    perform pg_temp.ok('P8', 'con sesión se llega a las funciones de lectura');

    -- Y la RPC llega a su lógica: rechaza por su propia validación, no por
    -- privilegio. Ese es el contraste que demuestra que la puerta está
    -- abierta para quien debe.
    begin
        perform public.trasladar_saldo(g, g, 'auth-mismo');
        raise exception '[P9] FALLA — ha aceptado destino igual al origen';
    exception
        when insufficient_privilege then
            raise exception '[P9] FALLA — authenticated NO puede ejecutar trasladar_saldo';
        when invalid_parameter_value then
            perform pg_temp.ok('P9', 'con sesión se llega a la lógica de trasladar_saldo');
    end;
end $$;
reset role;

-- ── Cerrar no ha roto los triggers ───────────────────────────
-- Las funciones de trigger ya no son ejecutables por nadie a mano. Lo que
-- hay que demostrar es que el motor las sigue disparando.
do $$
declare quien uuid; g uuid; n integer;
begin
    select id into quien from public.profiles order by created_at, id limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', quien)::text, true);

    insert into public.groups (id, name, created_by)
    values (gen_random_uuid(), 'Prueba de triggers', quien) returning id into g;

    -- `tras_crear_grupo` mete a su creador como propietario.
    select count(*) into n from public.group_members where group_id = g;
    if n <> 1 then
        raise exception '[P10] FALLA — el trigger de alta de grupo no ha disparado (% miembros)', n;
    end if;
    perform pg_temp.ok('P10', 'los triggers siguen disparando pese a no ser ejecutables a mano');

    delete from public.groups where id = g;
end $$;

-- ── El alta de usuarios sigue funcionando ────────────────────
do $$
declare n integer;
begin
    insert into auth.users (id, email, raw_user_meta_data)
    values ('abababab-abab-abab-abab-abababababab',
            'privilegios@ejemplo.invalido',
            '{"display_name":"Prueba Privilegios","color":"laurel"}'::jsonb);

    select count(*) into n from public.profiles
     where id = 'abababab-abab-abab-abab-abababababab';
    if n <> 1 then
        raise exception '[P11] FALLA — handle_new_user no ha creado el perfil';
    end if;
    perform pg_temp.ok('P11', 'el alta de usuarios sigue creando su perfil');
end $$;

do $$
declare n integer;
begin
    select count(*) into n from pr;
    if n <> 11 then
        raise exception 'Se esperaban 11 comprobaciones y han corrido %', n;
    end if;
    raise notice 'Privilegios de funciones: % comprobaciones superadas', n;
end $$;

rollback;

select 'Privilegios de funciones correctos' as resultado;
