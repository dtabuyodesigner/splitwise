-- ============================================================
-- P1, suelta · ninguna función de `public` abierta a PUBLIC ni a anon
--
-- Esta es LA garantía del asunto de los privilegios, y por eso vive también
-- fuera de 105: la ejecuta `aplicar-migraciones.sh` al final de cada
-- despliegue, para que una función nueva que se haya olvidado de su
--
--     revoke all on function <firma> from public, anon;
--
-- no llegue a quedarse abierta en producción.
--
-- Hace falta porque PostgreSQL concede EXECUTE a PUBLIC en toda función
-- nueva y eso NO se puede desactivar con `alter default privileges`: la
-- disciplina la impone esta comprobación, no el esquema.
--
-- Solo lectura.
-- ============================================================
\set ON_ERROR_STOP on

do $$
declare abiertas text;
begin
    select string_agg(
             p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
             || case when has_function_privilege('public', p.oid, 'execute')
                     then ' [PUBLIC]' else '' end
             || case when has_function_privilege('anon', p.oid, 'execute')
                     then ' [anon]' else '' end,
             E'\n  ')
      into abiertas
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.prokind = 'f'
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('public', p.oid, 'execute'));

    if abiertas is not null then
        raise exception
            E'Hay funciones de public ejecutables por PUBLIC o anon:\n  %\n'
            'Cada CREATE FUNCTION necesita su «revoke all on function <firma> from public, anon».',
            abiertas
            using errcode = 'insufficient_privilege';
    end if;

    raise notice 'Ninguna función de public es ejecutable por PUBLIC ni por anon';
end $$;

select 'Ninguna función abierta' as resultado;
