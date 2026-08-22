-- ============================================================
-- 0002 · Pertenencia a grupos
--
-- NO APLICADA. Requiere revisión previa: ver supabase/README.md §4 y
-- docs/PLAN-MIGRACION-DATOS.md.
--
-- Esta es la pieza que hoy falta y que hace imposible escribir una política
-- RLS de aislamiento: sin `group_members` no existe el dato con el que
-- decidir quién puede ver qué grupo.
--
-- El backfill del final es la parte DELICADA. Refleja el estado de hecho
-- actual de la aplicación (dos personas que comparten todos los grupos).
-- Si en la instalación real hubiera grupos que solo debe ver una de las dos
-- personas, este backfill los haría visibles para ambas. Hay que responder
-- a la pregunta 6 del informe antes de ejecutarlo.
-- ============================================================

create table if not exists public.group_members (
    group_id  uuid not null references public.groups(id)   on delete cascade,
    user_id   uuid not null references public.profiles(id) on delete cascade,
    role      text not null default 'member',
    joined_at timestamptz not null default now(),
    primary key (group_id, user_id),
    constraint group_members_role_valido check (role in ('owner', 'member'))
);

create index if not exists idx_group_members_user on public.group_members(user_id);
create index if not exists idx_group_members_group on public.group_members(group_id);

-- ------------------------------------------------------------
-- Función auxiliar: ¿es este usuario miembro de este grupo?
--
-- SECURITY DEFINER a propósito. Las políticas de `groups`, `expenses` y
-- `settlements` consultan `group_members`; si esa consulta pasara a su vez
-- por RLS, habría recursión infinita. Al ser DEFINER, la función salta RLS
-- pero solo devuelve un booleano, así que no filtra ninguna fila.
--
-- `search_path` fijado para que no se pueda secuestrar con una tabla
-- homónima en otro esquema.
-- ------------------------------------------------------------
create or replace function public.es_miembro(p_group_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.group_members
        where group_id = p_group_id and user_id = p_user_id
    );
$$;

revoke all on function public.es_miembro(uuid, uuid) from public;
grant execute on function public.es_miembro(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- Quien crea un grupo queda registrado como su propietario.
-- ------------------------------------------------------------
create or replace function public.registrar_creador_del_grupo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.created_by is null then
        new.created_by := auth.uid();
    end if;
    return new;
end;
$$;

drop trigger if exists antes_de_crear_grupo on public.groups;
create trigger antes_de_crear_grupo
    before insert on public.groups
    for each row execute function public.registrar_creador_del_grupo();

create or replace function public.apuntar_creador_como_miembro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.created_by is not null then
        insert into public.group_members (group_id, user_id, role)
        values (new.id, new.created_by, 'owner')
        on conflict do nothing;
    end if;
    return new;
end;
$$;

drop trigger if exists tras_crear_grupo on public.groups;
create trigger tras_crear_grupo
    after insert on public.groups
    for each row execute function public.apuntar_creador_como_miembro();

-- ============================================================
-- BACKFILL — LEER ANTES DE EJECUTAR
--
-- Deja el estado actual tal cual: los dos (o N) perfiles existentes pasan a
-- ser miembros de todos los grupos existentes. Es lo que la aplicación hace
-- hoy de hecho, así que nadie pierde acceso a nada al aplicarlo.
--
-- Solo es correcto si TODOS los grupos actuales son compartidos por todos
-- los perfiles actuales. Si no es el caso, hay que sustituir esta sentencia
-- por un backfill explícito grupo a grupo.
--
-- Está comentado a propósito. Descoméntalo únicamente después de haber
-- comprobado el resultado de las consultas de supabase/README.md §4.
-- ============================================================

-- OJO con el rol. `created_by` se acaba de añadir en 0001, así que TODOS los
-- grupos que ya existían lo tendrán a NULL. Con un `case when g.created_by =
-- p.id` a secas, nadie quedaría como 'owner' en ningún grupo histórico, y
-- como la política `groups_borrar` exige rol 'owner', esos grupos quedarían
-- IMBORRABLES para siempre. Por eso, en un grupo sin creador conocido, todos
-- sus miembros entran como propietarios: es lo coherente con el estado de
-- hecho actual (dos personas que comparten todo).
--
-- insert into public.group_members (group_id, user_id, role)
-- select g.id, p.id,
--        case when g.created_by is null or g.created_by = p.id
--             then 'owner' else 'member' end
-- from public.groups g
-- cross join public.profiles p
-- on conflict do nothing;

-- Comprobación posterior recomendada:
--   select g.name, count(m.user_id) as miembros
--   from public.groups g
--   left join public.group_members m on m.group_id = g.id
--   group by g.name order by miembros;
-- Ningún grupo debería quedar con 0 miembros: si lo hace, quedará invisible
-- para todo el mundo en cuanto se apliquen las políticas de 0004.
--
-- Y ninguno debería quedarse sin propietario:
--   select g.name from public.groups g
--   where not exists (
--       select 1 from public.group_members m
--       where m.group_id = g.id and m.role = 'owner'
--   );
-- Si devuelve algo, esos grupos no se podrán borrar desde la app.
