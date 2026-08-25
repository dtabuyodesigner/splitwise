-- ============================================================
-- Diagnóstico de privilegios de las funciones · SOLO LECTURA
--
-- Para el incidente E12: «trasladar_saldo es ejecutable por PUBLIC o anon».
--
-- No se limita a `information_schema.role_routine_grants`, que OMITE por
-- definición lo concedido a PUBLIC y no explica de dónde viene un permiso.
-- Aquí se pregunta a `has_function_privilege` rol por rol y se lee el
-- `proacl` en crudo, que es donde se ve si la concesión es directa.
--
-- No imprime UUID, correos, conceptos, importes ni cadenas de conexión.
-- ============================================================
\set ON_ERROR_STOP on

begin read only;

\echo '════ 1 · Las dos funciones del incidente, firma a firma ════'
select left(md5(p.oid::text), 8)                      as resorte,
       p.proname                                      as funcion,
       pg_get_function_identity_arguments(p.oid)      as firma,
       pg_get_function_result(p.oid)                  as devuelve,
       p.prosecdef                                    as security_definer,
       (select r.rolname from pg_roles r where r.oid = p.proowner) as propietario,
       coalesce(array_to_string(p.proacl, ' | '), '(sin acl: privilegios por defecto)') as acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('trasladar_saldo', 'revertir_traslado')
 order by p.proname, firma;

\echo '════ 2 · Privilegio EFECTIVO de EXECUTE, rol por rol ════'
select p.proname                                 as funcion,
       pg_get_function_identity_arguments(p.oid) as firma,
       has_function_privilege('public', p.oid, 'execute')        as publico,
       has_function_privilege('anon', p.oid, 'execute')          as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('service_role', p.oid, 'execute')  as service_role
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('trasladar_saldo', 'revertir_traslado')
 order by p.proname, firma;

\echo '════ 3 · ¿De dónde viene el permiso de anon? ════'
-- Tres orígenes posibles: PUBLIC, concesión directa, o herencia de otro rol.
select p.proname as funcion,
       exists (select 1 from aclexplode(p.proacl) a
                where a.grantee = 0 and a.privilege_type = 'EXECUTE')      as desde_public,
       exists (select 1 from aclexplode(p.proacl) a
                join pg_roles r on r.oid = a.grantee
                where r.rolname = 'anon' and a.privilege_type = 'EXECUTE') as concesion_directa_a_anon,
       (select coalesce(string_agg(r2.rolname, ', '), '(ninguno)')
          from pg_auth_members m
          join pg_roles r2 on r2.oid = m.roleid
          join pg_roles r1 on r1.oid = m.member
         where r1.rolname = 'anon')                                        as anon_hereda_de,
       (select coalesce(string_agg(r2.rolname, ', '), '(ninguno)')
          from pg_auth_members m
          join pg_roles r2 on r2.oid = m.roleid
          join pg_roles r1 on r1.oid = m.member
         where r1.rolname = 'authenticated')                               as authenticated_hereda_de
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('trasladar_saldo', 'revertir_traslado')
 order by 1;

\echo '════ 4 · ¿Hay sobrecargas? ════'
select p.proname as funcion, count(*) as sobrecargas,
       string_agg(pg_get_function_identity_arguments(p.oid), '  ||  ') as firmas
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('trasladar_saldo','revertir_traslado','saldo_centimos',
                     'pareja_del_grupo','puede_viajes','es_miembro','es_owner')
 group by p.proname order by 1;

\echo '════ 5 · La firma del REVOKE de 0007 vs la que comprueba E12 ════'
-- Si estas dos no resolvieran al MISMO oid, el revoke habría ido a otra
-- función y ese sería el fallo. Se comprueba explícitamente.
select to_regprocedure('public.trasladar_saldo(uuid,uuid,text,numeric)') is not null as firma_existe,
       (to_regprocedure('public.trasladar_saldo(uuid,uuid,text,numeric)')::oid
        = (select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.proname='trasladar_saldo' limit 1))       as misma_que_el_revoke,
       to_regprocedure('public.revertir_traslado(uuid)') is not null                 as revertir_existe;

\echo '════ 6 · TODAS las funciones del esquema public ════'
-- El incidente puede no ser exclusivo de estas dos.
select p.proname                                 as funcion,
       p.prosecdef                               as definer,
       (p.prorettype = 'trigger'::regtype)       as es_de_trigger,
       has_function_privilege('public', p.oid, 'execute') as publico,
       has_function_privilege('anon', p.oid, 'execute')   as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
 order by has_function_privilege('anon', p.oid, 'execute') desc, p.proname;

\echo '════ 7 · Privilegios POR DEFECTO del esquema ════'
-- Si aquí aparece `anon=X`, cada función nueva nacerá con EXECUTE para anon,
-- y un `revoke ... from public` NO lo quita: son concesiones distintas.
select (select r.rolname from pg_roles r where r.oid = d.defaclrole) as quien_los_fija,
       n.nspname                                                     as esquema,
       d.defaclobjtype                                               as tipo,
       array_to_string(d.defaclacl, ' | ')                           as privilegios_por_defecto
  from pg_default_acl d
  left join pg_namespace n on n.oid = d.defaclnamespace
 where d.defaclobjtype = 'f'
 order by 1, 2;

\echo '════ 8 · Resumen del caso ════'
select case
    when has_function_privilege('anon', 'public.trasladar_saldo(uuid,uuid,text,numeric)', 'execute')
         and exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                      join aclexplode(p.proacl) a on true
                      join pg_roles r on r.oid = a.grantee
                     where n.nspname='public' and p.proname='trasladar_saldo'
                       and r.rolname='anon' and a.privilege_type='EXECUTE')
        then 'A/C · FUGA REAL: anon tiene una concesion DIRECTA. El revoke de 0007 iba a PUBLIC, que es otra cosa.'
    when has_function_privilege('anon', 'public.trasladar_saldo(uuid,uuid,text,numeric)', 'execute')
        then 'A/E · anon puede ejecutar, pero no por concesion directa: revisar herencia de roles.'
    else 'D · FALSO POSITIVO: anon NO puede ejecutar.'
 end as veredicto;

commit;
