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
create table if not exists public.profiles (
    id           uuid primary key references auth.users(id) on delete cascade,
    display_name text not null default 'Sin nombre',
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
-- Sin esto, un usuario nuevo se autentica pero nunca aparece en la app.
-- Se define con CREATE OR REPLACE para no duplicar si ya existe uno.
-- Si en el proyecto real ya hay un trigger con OTRO nombre haciendo lo
-- mismo, hay que quitar uno de los dos antes de aplicar esta migración.
-- ------------------------------------------------------------
create or replace function public.crear_perfil_al_registrarse()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, display_name, color)
    values (
        new.id,
        coalesce(
            nullif(new.raw_user_meta_data ->> 'display_name', ''),
            -- split_part devuelve '' —no NULL— si el correo viene vacío,
            -- y coalesce no lo filtraría: el nombre quedaría en blanco.
            nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
            'Sin nombre'
        ),
        case when (select count(*) from public.profiles) = 0
             then 'laurel' else 'buganvilla' end
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

-- ------------------------------------------------------------
-- El trigger SOLO se crea si no hay ya otro haciendo lo mismo.
--
-- El inventario de producción reveló que YA EXISTE:
--     on_auth_user_created  AFTER INSERT ON auth.users
--     EXECUTE FUNCTION public.handle_new_user()
--
-- Dos triggers de alta compitiendo sobre la misma tabla pueden duplicar
-- filas, pisarse el `display_name` o el `color`, o hacerse fallar entre sí.
-- Y no se puede decidir cuál sobra sin leer antes qué hace el que ya está:
-- para eso está `supabase/pruebas/inspeccion-trigger-alta.sql`.
--
-- Así que esta migración NO toca `auth.users` si ya hay un trigger de
-- usuario ahí. Lo dice por consola y sigue. La función queda creada, por si
-- se decide reutilizarla, pero sin engancharse a nada.
--
-- Nota de entorno: `auth.users` pertenece a `supabase_auth_admin`. En la
-- mayoría de proyectos el rol `postgres` puede crear triggers sobre ella (es
-- el patrón que documenta la propia Supabase), pero según cómo esté
-- provisionado puede fallar con "must be owner of relation users". Si ocurre,
-- hay que crearlo desde el editor SQL del panel.
-- ------------------------------------------------------------
do $$
declare
    ya_existe text;
begin
    select string_agg(t.tgname, ', ') into ya_existe
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'auth' and rel.relname = 'users'
      and not t.tgisinternal
      and t.tgname <> 'al_crear_usuario';

    if ya_existe is not null then
        raise notice
            'auth.users ya tiene el trigger de alta "%": no se crea otro. '
            'Revisa supabase/pruebas/inspeccion-trigger-alta.sql y decide si '
            'reutilizarlo o sustituirlo.', ya_existe;
        return;
    end if;

    drop trigger if exists al_crear_usuario on auth.users;
    create trigger al_crear_usuario
        after insert on auth.users
        for each row execute function public.crear_perfil_al_registrarse();

    raise notice 'Creado el trigger al_crear_usuario sobre auth.users';
end $$;
