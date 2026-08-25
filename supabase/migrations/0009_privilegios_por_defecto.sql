-- ============================================================
-- 0009 · Privilegios por defecto de las funciones de `public`
--
-- Correctiva. 0007 y 0008 ya están desplegadas: esto no las reescribe.
--
-- ── Qué venía a arreglar ─────────────────────────────────────
--
-- 0008 ejecutó `alter default privileges in schema public revoke ... from
-- anon` SIN `for role`, y esa forma solo toca los privilegios por defecto
-- del rol que la ejecuta. En Supabase hay más de un rol con ACL por defecto
-- en `public` —al menos `postgres` y `supabase_admin`—, así que la entrada
-- de `supabase_admin` seguía concediendo EXECUTE a `anon`.
--
-- ── Hasta dónde llega, de verdad ─────────────────────────────
--
-- Una primera versión intentaba `alter default privileges for role
-- supabase_admin`, y produccción respondió:
--
--     permission denied to change default privileges
--
-- Es correcto: `supabase_admin` es un rol de la plataforma, no de esta
-- aplicación, y el rol con el que se despliega no lo administra. No se
-- intenta rodear eso de ninguna manera —ni SET ROLE, ni concederse el rol,
-- ni una función SECURITY DEFINER—: sería escalar privilegios para tocar
-- algo que no es nuestro.
--
-- Así que esta migración hace lo que le corresponde y **declara lo que no
-- puede hacer** en vez de fingir que lo ha hecho:
--
--   · retira las concesiones directas a `anon` y `authenticated` de los
--     roles que el ejecutor SÍ administra —en la práctica, `postgres`—;
--   · conserva `service_role`, que es el rol de servidor de confianza;
--   · enumera los roles que NO puede tocar y los registra como limitación
--     gestionada por Supabase. Sin abortar: abortar dejaría también sin
--     hacer la parte que sí está en su mano.
--
-- Y hay una segunda cosa que tampoco se puede: PostgreSQL concede EXECUTE a
-- PUBLIC en toda función nueva, y `revoke ... from public` en los privilegios
-- por defecto BORRA la fila y devuelve el esquema a ese mismo valor de serie.
-- Comprobado.
--
-- ── Dónde está entonces la garantía ──────────────────────────
--
-- No en el esquema, sino en la comprobación:
-- `supabase/pruebas/106_ninguna_funcion_abierta.sql` recorre TODAS las
-- funciones de `public` y falla si alguna es ejecutable por PUBLIC o por
-- `anon`. Corre en el CI y como última puerta de `aplicar-migraciones.sh`.
--
-- Y eso basta mientras se cumpla lo que sí controlamos: las funciones de
-- esta aplicación las crean sus migraciones, ejecutadas como `postgres`, así
-- que nacen con los privilegios por defecto de `postgres` —los que esta
-- migración sí limpia— y cada una revoca PUBLIC explícitamente.
--
-- Idempotente. Pensada para --single-transaction.
-- ============================================================

do $defaults$
declare
    d              record;
    modificados    text := '';
    no_modificables text := '';
    n_ok           integer := 0;
    n_no           integer := 0;
    pendientes     integer;
begin
    for d in
        select (select r.rolname from pg_roles r where r.oid = da.defaclrole) as rol
          from pg_default_acl da
          join pg_namespace ns on ns.oid = da.defaclnamespace
         where da.defaclobjtype = 'f'          -- solo funciones
           and ns.nspname = 'public'           -- solo el esquema de la aplicación
    loop
        if d.rol is null then
            continue;
        end if;

        -- Se intenta, y si no se puede se anota. No se comprueba antes con
        -- `pg_has_role` y ya está: el permiso para cambiar privilegios por
        -- defecto no se deduce solo de la pertenencia, y lo que importa es
        -- el resultado real, no nuestra predicción de él.
        begin
            execute format(
                'alter default privileges for role %I in schema public '
                'revoke execute on functions from anon', d.rol);
            execute format(
                'alter default privileges for role %I in schema public '
                'revoke execute on functions from authenticated', d.rol);

            modificados := modificados || ' ' || d.rol;
            n_ok := n_ok + 1;
        exception when insufficient_privilege then
            -- Rol de la plataforma. No es nuestro y no se fuerza.
            no_modificables := no_modificables || ' ' || d.rol;
            n_no := n_no + 1;
        end;
    end loop;

    if n_ok > 0 then
        raise notice 'Privilegios por defecto limpiados en el/los rol(es):%', modificados;
    end if;

    if n_no > 0 then
        raise notice
            'LIMITACION DECLARADA — sin permiso para cambiar los privilegios por defecto de:%. '
            'Son roles gestionados por Supabase, no de esta aplicacion. NO se han corregido.',
            no_modificables;
        raise notice
            '  No importa mientras se cumpla lo que si controlamos: las funciones de esta '
            'aplicacion las crean sus migraciones como `postgres`, y 106 comprueba que '
            'ninguna funcion de public queda abierta a PUBLIC ni a anon.';
    end if;

    -- Comprobación acotada a lo que esta migración sí gobierna: los roles
    -- que ha podido tocar no pueden seguir concediendo a anon ni a
    -- authenticated. Los que no ha podido quedan fuera a propósito: exigirlo
    -- haría fallar la migración por algo que no está en su mano.
    select count(*) into pendientes
      from pg_default_acl da
      join pg_namespace ns on ns.oid = da.defaclnamespace
      join aclexplode(da.defaclacl) a on true
      join pg_roles r on r.oid = a.grantee
      join pg_roles cre on cre.oid = da.defaclrole
     where da.defaclobjtype = 'f' and ns.nspname = 'public'
       and a.privilege_type = 'EXECUTE'
       and r.rolname in ('anon', 'authenticated')
       and position(' ' || cre.rolname in modificados) > 0;

    if pendientes > 0 then
        raise exception
            'Quedan % concesion(es) por defecto a anon o authenticated en roles que SI se administran',
            pendientes
            using errcode = 'insufficient_privilege';
    end if;

    raise notice
        'AVISO: PostgreSQL seguira concediendo EXECUTE a PUBLIC en cada funcion nueva. '
        'Cada migracion tiene que revocarlo, y 106 falla si se olvida.';
end
$defaults$;

-- ── Las funciones de esta aplicación son de `postgres` ───────
-- Es la condición de la que depende todo lo anterior: si las crearan bajo
-- `supabase_admin`, heredarían SUS privilegios por defecto, que no podemos
-- limpiar. Se comprueba aquí, en la propia migración, para que un cambio de
-- rol de despliegue no pase inadvertido.
do $duenos$
declare
    ajenas text;
begin
    select string_agg(p.proname || ' → ' || r.rolname, ', ')
      into ajenas
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
      join pg_roles r on r.oid = p.proowner
     where ns.nspname = 'public'
       and p.prokind = 'f'
       and p.proname in ('es_miembro','es_owner','puede_viajes','saldo_centimos',
                         'pareja_del_grupo','trasladar_saldo','revertir_traslado',
                         'handle_new_user','proteger_traslado',
                         'proteger_liquidacion_de_traslado','comprobar_traslado_coherente')
       and r.rolname <> current_user;

    if ajenas is not null then
        raise notice
            'AVISO: hay funciones de la aplicacion cuyo dueno no es %: %. '
            'Heredarian los privilegios por defecto de ESE rol.', current_user, ajenas;
    else
        raise notice 'Todas las funciones de la aplicacion pertenecen a %', current_user;
    end if;
end
$duenos$;
