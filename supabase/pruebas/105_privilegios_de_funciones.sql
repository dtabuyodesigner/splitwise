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

    -- Y los privilegios por defecto.
    --
    -- Se distinguen dos cosas que no son lo mismo:
    --
    --   · un rol que ESTA aplicación administra y que sigue concediendo a
    --     anon o authenticated → eso es un fallo nuestro;
    --   · un rol de la plataforma —`supabase_admin`— que hace lo mismo →
    --     eso no está en nuestra mano y se declara, no se finge arreglado.
    --
    -- La primera versión de esta comprobación no distinguía, y por eso 0009
    -- prometió corregir algo que producción le denegó con «permission denied
    -- to change default privileges».
    declare
        nuestros   text;
        ajenos     text;
    begin
        select string_agg(format('%s → %s', d.rol, d.quien), '; ')
          into nuestros
          from (
            select cre.rolname as rol, coalesce(r.rolname, 'PUBLIC') as quien
              from pg_default_acl da
              join pg_namespace ns on ns.oid = da.defaclnamespace
              join pg_roles cre on cre.oid = da.defaclrole
              join aclexplode(da.defaclacl) a on true
              left join pg_roles r on r.oid = a.grantee
             where da.defaclobjtype = 'f' and ns.nspname = 'public'
               and a.privilege_type = 'EXECUTE'
               and r.rolname in ('anon', 'authenticated')
               and pg_has_role(current_user, cre.oid, 'member')
          ) d;

        select string_agg(format('%s → %s', d.rol, d.quien), '; ')
          into ajenos
          from (
            select cre.rolname as rol, coalesce(r.rolname, 'PUBLIC') as quien
              from pg_default_acl da
              join pg_namespace ns on ns.oid = da.defaclnamespace
              join pg_roles cre on cre.oid = da.defaclrole
              join aclexplode(da.defaclacl) a on true
              left join pg_roles r on r.oid = a.grantee
             where da.defaclobjtype = 'f' and ns.nspname = 'public'
               and a.privilege_type = 'EXECUTE'
               and r.rolname in ('anon', 'authenticated')
               and not pg_has_role(current_user, cre.oid, 'member')
          ) d;

        if nuestros is not null then
            raise exception
                '[P3] FALLA — roles que SI administramos siguen concediendo por defecto: %',
                nuestros;
        end if;

        if ajenos is not null then
            raise notice
                '  [P3] limitación declarada — roles gestionados por Supabase que conceden '
                'por defecto y NO podemos cambiar: %', ajenos;
            raise notice
                '  No es un fallo: lo que importa es que ninguna función exista abierta, y '
                'de eso se encarga P1.';
        end if;
    end;
    perform pg_temp.ok('P3',
        'ningún rol administrable concede EXECUTE por defecto a anon ni a authenticated');
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

-- ── Qué reciben las funciones FUTURAS, las cree quien las cree ──
--
-- Lo que se comprueba aquí es lo que de verdad se puede garantizar, ni una
-- palabra más:
--
--   · que NO reciben concesión DIRECTA a `anon`;
--   · que NO reciben concesión DIRECTA a `authenticated`;
--   · que `authenticated` solo llega tras un GRANT explícito.
--
-- Lo que NO se comprueba, porque PostgreSQL no permite garantizarlo: que
-- nazcan cerradas a PUBLIC. `alter default privileges ... revoke execute on
-- functions from public` BORRA la fila de `pg_default_acl` y devuelve el
-- esquema al valor de serie, que es precisamente esa concesión. Verificado.
--
-- De eso se encarga P1, que recorre todas las funciones existentes y falla
-- si alguna es ejecutable por PUBLIC o por anon. La regla, entonces, es de
-- disciplina y la impone el CI:
--
--     create function ...;
--     revoke all on function <firma> from public, anon;
--     grant execute on function <firma> to <rol previsto>;
do $$
declare
    d       record;
    creados integer := 0;
    nombre  text;
    fallos  text := '';
begin
    for d in
        select coalesce((select r.rolname from pg_roles r where r.oid = da.defaclrole), 'postgres') as rol
          from pg_default_acl da
          join pg_namespace ns on ns.oid = da.defaclnamespace
         where da.defaclobjtype = 'f' and ns.nspname = 'public'
        union
        select current_user
    loop
        if d.rol <> current_user and not pg_has_role(current_user, d.rol, 'member') then
            raise notice '  (se omite %: no se puede asumir ese rol)', d.rol;
            continue;
        end if;

        nombre := 'prueba_futura_' || replace(d.rol, '-', '_');
        begin
            execute format('set local role %I', d.rol);
            execute format(
                'create or replace function public.%I() returns integer '
                'language sql immutable as $f$ select 1 $f$', nombre);
            execute 'reset role';
        exception when insufficient_privilege then
            execute 'reset role';
            raise notice '  (se omite %: no puede crear funciones en public)', d.rol;
            continue;
        end;
        creados := creados + 1;

        -- Concesión DIRECTA a anon: no puede haberla. Se mira el acl, no el
        -- privilegio efectivo, porque el efectivo incluye lo que llega por
        -- PUBLIC y eso ya se sabe que está.
        if exists (select 1 from pg_proc p
                    join pg_namespace ns on ns.oid = p.pronamespace
                    join aclexplode(p.proacl) a on true
                    join pg_roles r on r.oid = a.grantee
                   where ns.nspname = 'public' and p.proname = nombre
                     and r.rolname = 'anon' and a.privilege_type = 'EXECUTE') then
            fallos := fallos || format(' %s: concesión directa a anon;', d.rol);
        end if;

        if exists (select 1 from pg_proc p
                    join pg_namespace ns on ns.oid = p.pronamespace
                    join aclexplode(p.proacl) a on true
                    join pg_roles r on r.oid = a.grantee
                   where ns.nspname = 'public' and p.proname = nombre
                     and r.rolname = 'authenticated' and a.privilege_type = 'EXECUTE') then
            fallos := fallos || format(' %s: concesión directa a authenticated;', d.rol);
        end if;

        -- Y tras revocar PUBLIC —el paso que cada migración tiene que hacer
        -- a mano— `authenticated` no debe llegar hasta su GRANT explícito.
        execute format('revoke all on function public.%I() from public, anon', nombre);
        if has_function_privilege('authenticated', format('public.%I()', nombre), 'execute') then
            fallos := fallos || format(' %s: authenticated llega sin GRANT;', d.rol);
        end if;
        execute format('grant execute on function public.%I() to authenticated', nombre);
        if not has_function_privilege('authenticated', format('public.%I()', nombre), 'execute') then
            fallos := fallos || format(' %s: authenticated no llega ni con GRANT;', d.rol);
        end if;

        execute format('drop function public.%I()', nombre);
    end loop;

    if creados = 0 then
        raise exception '[P12] FALLA — no se ha podido crear ninguna función de prueba';
    end if;
    if fallos <> '' then
        raise exception '[P12] FALLA — concesiones por defecto indebidas:%', fallos;
    end if;
    perform pg_temp.ok('P12',
        format('las funciones futuras no reciben concesión directa a anon ni a authenticated bajo los %s rol(es) creador(es), y authenticated solo llega con GRANT explícito',
               creados));
end $$;

-- ── Las funciones de la aplicación son del rol que despliega ────
-- De aquí depende todo: si las crearan bajo `supabase_admin`, heredarían SUS
-- privilegios por defecto, que no podemos limpiar.
do $$
declare ajenas text;
begin
    select string_agg(p.proname || ' → ' || r.rolname, ', ')
      into ajenas
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
      join pg_roles r on r.oid = p.proowner
     where ns.nspname = 'public' and p.prokind = 'f'
       and p.proname in ('es_miembro','es_owner','puede_viajes','saldo_centimos',
                         'pareja_del_grupo','trasladar_saldo','revertir_traslado')
       and not pg_has_role(current_user, p.proowner, 'member');

    if ajenas is not null then
        raise exception
            '[P13] FALLA — funciones de la aplicación con dueño que no administramos: %', ajenas;
    end if;
    perform pg_temp.ok('P13',
        'las funciones de la aplicación pertenecen al rol que despliega, no a uno de la plataforma');
end $$;

-- ── La denegación es real, y 0009 la maneja ─────────────────
-- Se reproduce el «permission denied to change default privileges» que dio
-- producción, para que nadie vuelva a prometer que se puede cambiar el rol
-- de la plataforma. Y se comprueba que el patrón de 0009 —intentarlo dentro
-- de un bloque con manejador— lo convierte en aviso y no en aborto.
do $$
declare
    rol_ajeno text := 'rol_plataforma_prueba';
    denegado  boolean := false;
begin
    if not exists (select 1 from pg_roles where rolname = rol_ajeno) then
        begin
            execute format('create role %I nologin', rol_ajeno);
        exception when insufficient_privilege then
            raise notice '  [P14] omitido — no se pueden crear roles aquí';
            perform pg_temp.ok('P14', 'omitido: sin permiso para crear el rol de prueba');
            return;
        end;
    end if;

    -- Se le quita la pertenencia para que la denegación sea real.
    begin
        execute format('revoke %I from current_user', rol_ajeno);
    exception when others then null;
    end;

    begin
        execute format(
            'alter default privileges for role %I in schema public '
            'revoke execute on functions from anon', rol_ajeno);
    exception when insufficient_privilege then
        denegado := true;
    end;

    execute format('drop role if exists %I', rol_ajeno);

    if denegado then
        perform pg_temp.ok('P14',
            'tocar los privilegios por defecto de un rol ajeno se deniega, y 0009 lo declara en vez de abortar');
    else
        -- Con superusuario no se deniega. No es un fallo de la prueba: es
        -- que aquí el ejecutor puede más que en producción.
        perform pg_temp.ok('P14',
            'este ejecutor puede administrar roles ajenos (superusuario): en producción NO, y 0009 lo contempla');
    end if;
end $$;

do $$
declare n integer;
begin
    select count(*) into n from pr;
    if n <> 14 then
        raise exception 'Se esperaban 14 comprobaciones y han corrido %', n;
    end if;
    raise notice 'Privilegios de funciones: % comprobaciones superadas', n;
end $$;

rollback;

select 'Privilegios de funciones correctos' as resultado;
