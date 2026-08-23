-- ============================================================
--  INSPECCIÓN DEL TRIGGER DE ALTA EXISTENTE · SOLO LECTURA
--
--  Producción ya tiene:
--      on_auth_user_created  AFTER INSERT ON auth.users
--      EXECUTE FUNCTION public.handle_new_user()
--
--  La migración 0001 no debe crear un segundo trigger sobre auth.users sin
--  saber qué hace el que ya existe: dos triggers de alta compitiendo pueden
--  duplicar filas, pisarse el display_name o el color, o fallar entre sí.
--
--  Esta consulta NO devuelve correos ni datos de usuarios: solo lee los
--  catálogos pg_proc y pg_trigger.
--
--  Es un único SELECT por bloque. Sin INSERT, UPDATE, DELETE, ALTER, CREATE,
--  DROP, GRANT ni REVOKE.
-- ============================================================

-- 1 · La función: definición completa, propietario, seguridad y search_path
select
    p.proname                                   as funcion,
    pg_get_userbyid(p.proowner)                 as propietario,
    p.prosecdef                                 as security_definer,
    coalesce(array_to_string(p.proconfig, ' | '), '(sin search_path fijado)') as configuracion,
    l.lanname                                   as lenguaje,
    pg_get_function_identity_arguments(p.oid)   as argumentos,
    pg_get_functiondef(p.oid)                   as definicion_completa
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_language  l on l.oid = p.prolang
where n.nspname = 'public'
  and p.proname in ('handle_new_user', 'crear_perfil_al_registrarse');

-- 2 · Privilegios de ejecución sobre esa función
select
    p.proname                       as funcion,
    coalesce(array_to_string(p.proacl::text[], ' | '),
             '(por defecto: EXECUTE para PUBLIC)') as privilegios
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'handle_new_user';

-- 3 · Todos los triggers sobre auth.users, con su definición exacta
select
    t.tgname                        as trigger,
    rel.relname                     as tabla,
    t.tgenabled                     as habilitado,   -- O=siempre D=deshabilitado
    pg_get_triggerdef(t.oid)        as definicion
from pg_trigger t
join pg_class rel on rel.oid = t.tgrelid
join pg_namespace n on n.oid = rel.relnamespace
where n.nspname = 'auth' and rel.relname = 'users'
  and not t.tgisinternal
order by t.tgname;

-- 4 · Qué columnas tiene profiles hoy, para comprobar que la función existente
--     rellena lo mismo que espera la aplicación (display_name y color)
select column_name as columna, data_type as tipo,
       is_nullable as acepta_null, column_default as por_defecto
from information_schema.columns
where table_schema = 'public' and table_name = 'profiles'
order by ordinal_position;

-- 5 · ¿Los dos perfiles existentes tienen color y nombre? (sin devolver
--     ni el nombre ni el correo: solo si están rellenos)
select
    count(*)                                          as perfiles,
    count(*) filter (where display_name is not null
                       and display_name <> '')        as con_nombre,
    count(*) filter (where color is not null)         as con_color,
    count(distinct color)                             as colores_distintos
from public.profiles;
