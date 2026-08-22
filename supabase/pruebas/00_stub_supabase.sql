-- ============================================================
-- Sustituto mínimo de lo que Supabase añade a una base PostgreSQL.
--
-- Se usa SOLO en CI, sobre una base vacía y desechable, para comprobar que
-- las migraciones compilan. No forma parte de las migraciones y nunca debe
-- ejecutarse contra una base real.
-- ============================================================

create schema if not exists auth;

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin;
    end if;
end $$;

create table if not exists auth.users (
    id                  uuid primary key default gen_random_uuid(),
    email               text,
    raw_user_meta_data  jsonb default '{}'::jsonb,
    created_at          timestamptz not null default now()
);

-- En Supabase devuelve el id del usuario del JWT. Aquí, null: basta para
-- que las políticas compilen.
create or replace function auth.uid() returns uuid
language sql stable as $$ select null::uuid $$;

grant usage on schema public to anon, authenticated;
