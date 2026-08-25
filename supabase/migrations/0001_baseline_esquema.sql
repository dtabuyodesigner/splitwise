-- ============================================================
-- 0001 · Línea base del esquema
--
-- ATENCIÓN: esta migración NO se ha aplicado a producción y NO se ha
-- validado contra el esquema real, porque no se ha tenido acceso al
-- proyecto Supabase. Ver supabase/README.md antes de ejecutar nada.
--
-- Objetivo: dejar en el repositorio, versionado, el esquema que la
-- aplicación da por supuesto. En un entorno nuevo (local o staging) crea
-- las tablas desde cero. En producción, donde ya existen, todas las
-- sentencias son IF NOT EXISTS y no tocan ni un dato.
-- ============================================================

-- gen_random_uuid() es nativo desde PostgreSQL 13, así que no hace falta
-- instalar pgcrypto. (Instalarla sin `schema extensions` la dejaría en
-- `public`, cosa que el linter de Supabase marca.)

-- ------------------------------------------------------------
-- profiles: una fila por usuario de auth.users
-- ------------------------------------------------------------
-- Igual que en producción, comprobado por inventario: `display_name` es NOT
-- NULL y SIN valor por defecto (lo rellena siempre el trigger de alta), y
-- `color` es NOT NULL con 'laurel' por defecto.
create table if not exists public.profiles (
    id           uuid primary key references auth.users(id) on delete cascade,
    display_name text not null,
    color        text not null default 'laurel',
    created_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
-- groups
-- ------------------------------------------------------------
create table if not exists public.groups (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    -- La clave foránea de created_by se añade en 0003, con nombre explícito.
    -- Declararla también aquí crearía una segunda FK idéntica en las bases
    -- nuevas, porque la guarda de 0003 busca por nombre de constraint.
    created_by uuid,
    created_at timestamptz not null default now()
);

-- `created_by` puede no existir en la base actual: se añade sin romper nada.
alter table public.groups add column if not exists created_by uuid;

-- ------------------------------------------------------------
-- expenses
-- ------------------------------------------------------------
create table if not exists public.expenses (
    id          uuid primary key default gen_random_uuid(),
    group_id    uuid not null,
    paid_by     uuid not null,
    amount      numeric(12,2) not null,
    description text not null default '',
    category    text not null default 'otros',
    payer_share numeric(5,4) not null default 0.5,
    spent_on    date not null default current_date,
    client_id   text,
    created_at  timestamptz not null default now()
);

-- ------------------------------------------------------------
-- settlements
-- ------------------------------------------------------------
create table if not exists public.settlements (
    id         uuid primary key default gen_random_uuid(),
    group_id   uuid not null,
    from_user  uuid not null,
    to_user    uuid not null,
    amount     numeric(12,2) not null,
    note       text,
    settled_on date not null default current_date,
    client_id  text,
    created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Alta automática del perfil al registrarse
--
-- Producción YA tiene este mecanismo, y el inventario lo confirmó:
--
--     trigger  on_auth_user_created  AFTER INSERT ON auth.users
--     función  public.handle_new_user()  · plpgsql · SECURITY DEFINER
--              · propietario postgres · search_path=public
--
-- Esta migración NO lo sustituye. Lo que hace es:
--
--   · si la función ya existe, la deja intacta;
--   · si no existe (instalación limpia), la crea con el MISMO contrato,
--     para que un entorno nuevo se comporte igual que producción;
--   · el trigger solo se crea si `auth.users` no tiene ya uno.
--
-- El contrato de la función, tal y como está en producción:
--   display_name ← raw_user_meta_data.display_name, o full_name, o name,
--                  o la parte anterior a la @ del correo
--   color        ← raw_user_meta_data.color, o 'laurel' para el primer
--                  perfil y 'buganvilla' para los siguientes
--   ON CONFLICT (id) DO NOTHING, y devuelve NEW
--
-- Nota de entorno: `auth.users` pertenece a `supabase_auth_admin`. En la
-- mayoría de proyectos el rol `postgres` puede crear triggers sobre ella,
-- pero según cómo esté provisionado puede fallar con "must be owner of
-- relation users". Si ocurre, hay que crearlo desde el editor SQL del panel.
-- ------------------------------------------------------------
do $crear_funcion$
begin
    -- Se comprueba por esquema, nombre Y firma: `public.handle_new_user()` sin
    -- argumentos y devolviendo `trigger`. Buscar solo por `proname` daría un
    -- falso positivo con cualquier función homónima de otra firma o de otro
    -- esquema, y entonces no se crearía la que hace falta.
    if to_regprocedure('public.handle_new_user()') is not null
       and exists (
           select 1 from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname = 'handle_new_user'
             and p.pronargs = 0
             and p.prorettype = 'pg_catalog.trigger'::regtype
       )
    then
        raise notice
            'public.handle_new_user() ya existe con la firma esperada: se conserva, no se sustituye.';
        return;
    end if;

    execute $ddl$
        create function public.handle_new_user()
        returns trigger
        language plpgsql
        security definer
        set search_path = public
        as $cuerpo$
        begin
            insert into public.profiles (id, display_name, color)
            values (
                new.id,
                coalesce(
                    nullif(new.raw_user_meta_data ->> 'display_name', ''),
                    nullif(new.raw_user_meta_data ->> 'full_name', ''),
                    nullif(new.raw_user_meta_data ->> 'name', ''),
                    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
                    'Sin nombre'
                ),
                coalesce(
                    nullif(new.raw_user_meta_data ->> 'color', ''),
                    case when (select count(*) from public.profiles) = 0
                         then 'laurel' else 'buganvilla' end
                )
            )
            on conflict (id) do nothing;
            return new;
        end;
        $cuerpo$;
    $ddl$;

    raise notice 'Creada public.handle_new_user() para una instalación limpia.';
end
$crear_funcion$;

-- El trigger SOLO se crea si `auth.users` no tiene ya uno. Dos mecanismos de
-- alta compitiendo pueden duplicar filas o pisarse display_name y color.
do $crear_trigger$
declare
    el_de_perfiles text;
    ocupa_el_nombre text;
begin
    -- Lo que importa no es que `auth.users` tenga ALGÚN trigger, sino que
    -- tenga uno que cree perfiles. Un trigger ajeno —de auditoría, de
    -- analítica, de lo que sea— no debe impedir instalar el mecanismo de
    -- perfiles: si lo hiciera, los usuarios nuevos no aparecerían nunca en
    -- la aplicación.
    select string_agg(t.tgname, ', ') into el_de_perfiles
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace fn on fn.oid = p.pronamespace
    where n.nspname = 'auth' and rel.relname = 'users'
      and not t.tgisinternal
      and fn.nspname = 'public'
      and p.proname = 'handle_new_user'
      and p.pronargs = 0;

    if el_de_perfiles is not null then
        raise notice
            'auth.users ya tiene el trigger de alta de perfiles "%": no se crea otro.',
            el_de_perfiles;
        return;
    end if;

    -- No hay ninguno que cree perfiles. ¿Está el nombre ocupado por otra cosa?
    -- Si lo está, NO se pisa: podría ser un trigger de otra aplicación.
    select string_agg(t.tgname, ', ') into ocupa_el_nombre
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'auth' and rel.relname = 'users'
      and not t.tgisinternal
      and t.tgname = 'on_auth_user_created';

    if ocupa_el_nombre is not null then
        -- EXCEPTION, no NOTICE. Un `return` aquí solo abandonaría este bloque
        -- DO: la migración seguiría y el despliegue terminaría con apariencia
        -- de correcto, pero SIN ningún mecanismo que cree perfiles. Los
        -- usuarios nuevos se autenticarían y no aparecerían nunca en la
        -- aplicación, y nadie se enteraría hasta que alguien se registrara.
        --
        -- El trigger ajeno NO se toca: podría ser de otra aplicación de esta
        -- misma base. Decidir qué hacer con él es cosa de una persona.
        raise exception
            'Existe un trigger llamado on_auth_user_created que NO ejecuta public.handle_new_user()'
            using hint = 'No se ha tocado: podría ser de otra aplicación. Revísalo con '
                         'supabase/pruebas/inspeccion-trigger-alta.sql y decide si '
                         'renombrarlo o sustituirlo. Sin un mecanismo de alta, los '
                         'usuarios nuevos no aparecerán nunca en la aplicación.',
                  errcode = 'object_not_in_prerequisite_state';
    end if;

    create trigger on_auth_user_created
        after insert on auth.users
        for each row execute function public.handle_new_user();

    raise notice 'Creado el trigger on_auth_user_created sobre auth.users.';
end
$crear_trigger$;
