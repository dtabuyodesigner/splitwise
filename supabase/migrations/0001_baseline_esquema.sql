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

create extension if not exists "pgcrypto";

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
    created_by uuid references public.profiles(id) on delete set null,
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
            split_part(new.email, '@', 1),
            'Sin nombre'
        ),
        case when (select count(*) from public.profiles) = 0
             then 'laurel' else 'buganvilla' end
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario
    after insert on auth.users
    for each row execute function public.crear_perfil_al_registrarse();
