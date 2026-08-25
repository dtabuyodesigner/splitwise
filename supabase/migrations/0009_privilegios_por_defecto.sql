-- ============================================================
-- 0009 · Cerrar los privilegios POR DEFECTO de las funciones futuras
--
-- Correctiva. 0007 y 0008 ya están desplegadas: esto no las reescribe.
--
-- Qué quedaba suelto. 0008 cerró las quince funciones que existían, y ejecutó
--
--     alter default privileges in schema public revoke execute on functions from anon;
--
-- pero esa forma, sin `FOR ROLE`, solo afecta a los privilegios por defecto
-- del rol que la ejecuta. En Supabase hay MÁS de un rol creador con ACL por
-- defecto en `public` —al menos `postgres` y `supabase_admin`—, así que la
-- entrada de `supabase_admin` seguía concediendo EXECUTE a `anon` sobre toda
-- función futura. La siguiente migración habría vuelto a abrirlo todo.
--
-- Aquí se recorren TODOS los roles que tengan ACL por defecto de funciones en
-- `public`, sea cual sea. Enumerar es lo único que cubre a los que no
-- conocemos.
--
-- Qué NO toca: ni `auth`, ni `storage`, ni `graphql`, ni `extensions`, ni
-- `realtime`, ni las ACL de ninguna función fuera de `public`. Solo los
-- valores por defecto del esquema `public`.
--
-- ── Hasta dónde llega esto, dicho sin adornos ────────────────
--
-- PostgreSQL concede `EXECUTE` a `PUBLIC` sobre toda función nueva, y eso NO
-- se puede quitar desde aquí. Comprobado: `alter default privileges ...
-- revoke execute on functions from public` BORRA la fila de `pg_default_acl`
-- y devuelve el esquema al valor de serie, que es precisamente esa concesión
-- a PUBLIC. La orden se acepta y no hace nada.
--
-- Así que lo que 0009 sí consigue es quitar las concesiones DIRECTAS a
-- `anon` y `authenticated`, que son las que Supabase añade y sí se pueden
-- revocar. Lo que NO consigue es que una función futura nazca cerrada a
-- PUBLIC: eso hay que revocarlo función por función, como hace 0008.
--
-- La garantía de verdad, entonces, no está en esta migración: está en la
-- prueba P1, que recorre todas las funciones de `public` y falla en el CI si
-- alguna es ejecutable por `anon` o por PUBLIC. Una migración que se olvide
-- de su `revoke` no llega a producción. Es menos elegante que un ajuste de
-- esquema, pero es lo que de verdad se puede cumplir.
--
-- Idempotente. Pensada para --single-transaction.
-- ============================================================

do $defaults$
declare
    d          record;
    n          integer := 0;
    sin_grants integer := 0;
begin
    for d in
        select (select r.rolname from pg_roles r where r.oid = da.defaclrole) as rol,
               da.defaclacl
          from pg_default_acl da
          join pg_namespace ns on ns.oid = da.defaclnamespace
         where da.defaclobjtype = 'f'          -- solo funciones
           and ns.nspname = 'public'           -- solo el esquema de la aplicación
    loop
        if d.rol is null then
            continue;
        end if;

        -- anon y PUBLIC fuera, en las funciones que cree este rol de aquí en
        -- adelante.
        execute format(
            'alter default privileges for role %I in schema public '
            'revoke execute on functions from anon',
            d.rol);
        -- A PUBLIC no se le puede quitar desde aquí (ver la cabecera), pero
        -- se intenta igualmente: si en alguna versión futura de PostgreSQL
        -- pasara a funcionar, esto ya estaría puesto.
        execute format(
            'alter default privileges for role %I in schema public '
            'revoke execute on functions from public',
            d.rol);

        -- Y tampoco `authenticated` por defecto: cada RPC pública tiene que
        -- recibir su GRANT explícito. Es lo que convierte «exponer una
        -- función» en una decisión y no en un descuido — que es justo cómo
        -- llegó `trasladar_saldo` a estar al alcance del rol anónimo.
        execute format(
            'alter default privileges for role %I in schema public '
            'revoke execute on functions from authenticated',
            d.rol);

        raise notice 'Privilegios por defecto cerrados para el rol creador: %', d.rol;
        n := n + 1;
    end loop;

    if n = 0 then
        raise notice 'No hay ningún privilegio por defecto de funciones en public: nada que cerrar';
    end if;

    -- `service_role` se deja como está a propósito: es el rol de servidor de
    -- confianza de Supabase, no llega desde el navegador, y quitárselo puede
    -- romper piezas de la plataforma que no son de esta aplicación.

    -- Comprobación: no puede quedar ni un rol creador que conceda EXECUTE
    -- DIRECTAMENTE a anon o a authenticated. PUBLIC se queda fuera de esta
    -- comprobación a propósito: no se puede quitar, y exigirlo aquí haría
    -- fallar la migración por algo que no está en su mano.
    select count(*) into sin_grants
      from pg_default_acl da
      join pg_namespace ns on ns.oid = da.defaclnamespace
      join aclexplode(da.defaclacl) a on true
      join pg_roles r on r.oid = a.grantee
     where da.defaclobjtype = 'f' and ns.nspname = 'public'
       and a.privilege_type = 'EXECUTE'
       and r.rolname in ('anon', 'authenticated');

    if sin_grants > 0 then
        raise exception
            'Siguen quedando % concesión(es) por defecto a anon o authenticated', sin_grants
            using errcode = 'insufficient_privilege';
    end if;

    raise notice 'Ningún rol creador concede ya EXECUTE por defecto a anon ni a authenticated';
    raise notice 'AVISO: PostgreSQL seguirá dando EXECUTE a PUBLIC en cada función nueva. '
                 'Cada migración tiene que revocarlo, y la prueba P1 falla en el CI si se olvida.';
end
$defaults$;
