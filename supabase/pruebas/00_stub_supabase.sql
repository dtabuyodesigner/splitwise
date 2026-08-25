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
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin;
    end if;
end $$;

create table if not exists auth.users (
    id                  uuid primary key default gen_random_uuid(),
    email               text,
    raw_user_meta_data  jsonb default '{}'::jsonb,
    created_at          timestamptz not null default now()
);

-- Igual que en Supabase: lee el `sub` del JWT. Las pruebas lo simulan con
--   set local request.jwt.claims = '{"sub":"<uuid>"}';
create or replace function auth.uid() returns uuid
language sql stable as $$
    select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$;

grant usage on schema public to anon, authenticated;

-- ------------------------------------------------------------
--  Permisos sobre el esquema `auth`
--
--  Reproduce lo MÍNIMO que Supabase concede para que las políticas RLS
--  puedan invocar `auth.uid()`. Sin esto, cualquier consulta hecha como
--  `authenticated` falla con:
--
--      ERROR: permission denied for schema auth
--      QUERY: auth.uid() ...
--
--  que es exactamente lo que detenía a 98_seguridad_dml.sql en su primera
--  aserción, antes de llegar a comprobar ninguna política.
--
--  Se conceden dos cosas y solo dos: USAGE sobre el esquema (poder
--  "entrar") y EXECUTE sobre la función (poder llamarla). Nada más.
-- ------------------------------------------------------------
grant usage on schema auth to anon, authenticated;

-- EXECUTE se concede a PUBLIC por defecto en PostgreSQL; se revoca primero
-- para que el permiso quede explícito y acotado a los dos roles.
revoke all on function auth.uid() from public;
grant execute on function auth.uid() to anon, authenticated;

-- `auth.users` NO se expone a los roles de aplicación. En Supabase solo la
-- leen `supabase_auth_admin` y `service_role`. Poder llamar a `auth.uid()`
-- no debe implicar poder leer la tabla de usuarios: 98_seguridad_dml.sql
-- comprueba explícitamente que sigue siendo inaccesible (aserción S02).
revoke all on table auth.users from public;
revoke all on table auth.users from anon, authenticated;

-- Para que las pruebas puedan hacer `set local role authenticated`.
do $$
begin
    execute 'grant authenticated to ' || quote_ident(current_user);
    execute 'grant anon to ' || quote_ident(current_user);
exception when others then null;   -- ya concedido
end $$;

-- ── Los privilegios POR DEFECTO de Supabase ──────────────────
-- Esto es lo que de verdad tiene el proyecto real: toda función nueva del
-- esquema `public` nace con EXECUTE para anon, authenticated y service_role.
--
-- Sin ponerlo aquí, el CI corría sobre una base más cerrada que producción y
-- daba por buena una migración que allí dejaba las funciones abiertas al rol
-- anónimo. Es exactamente lo que dejó pasar el incidente E12: la prueba no
-- reproducía la condición que causaba el fallo.
alter default privileges in schema public
    grant execute on functions to anon, authenticated, service_role;
