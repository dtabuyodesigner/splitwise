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
-- ¿es este usuario PROPIETARIO de este grupo?
--
-- Misma técnica y mismas garantías que `es_miembro`, y por el mismo motivo:
-- las políticas de UPDATE y DELETE de `group_members` necesitan comprobar la
-- propiedad, y si lo hicieran con una subconsulta sobre `group_members` la
-- expansión de RLS volvería a entrar en la misma tabla. PostgreSQL lo corta
-- con:
--
--     ERROR: infinite recursion detected in policy for relation "group_members"
--
-- Al ser SECURITY DEFINER, la función salta RLS; y como solo devuelve un
-- booleano, no filtra ninguna fila. `search_path` fijado para que no se pueda
-- secuestrar con una tabla homónima en otro esquema.
-- ------------------------------------------------------------
create or replace function public.es_owner(p_group_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.group_members
        where group_id = p_group_id and user_id = p_user_id and role = 'owner'
    );
$$;

revoke all on function public.es_owner(uuid, uuid) from public;
grant execute on function public.es_owner(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- Un grupo no puede quedarse sin propietario
--
-- Esto NO se puede expresar con RLS: RLS decide fila a fila, y aquí la regla
-- depende de las DEMÁS filas del grupo ("¿queda algún otro owner?"). Va en un
-- trigger, que es transaccional y no se puede saltar desde el cliente.
--
-- Sin esta regla, el último propietario podría degradarse o marcharse y dejar
-- el grupo sin nadie que pueda borrarlo ni administrarlo: exactamente el
-- estado del que la migración 0002 intenta salir.
-- ------------------------------------------------------------
create or replace function public.proteger_ultimo_propietario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    pierde_owner boolean;
    quedan       integer;
begin
    pierde_owner := (tg_op = 'DELETE' and old.role = 'owner')
                 or (tg_op = 'UPDATE' and old.role = 'owner' and new.role is distinct from 'owner');

    if not pierde_owner then
        return coalesce(new, old);
    end if;

    -- Si el grupo ya no existe, esto es el CASCADE de borrar el grupo entero:
    -- no hay invariante que proteger. (En PostgreSQL la fila padre se borra
    -- antes de que se disparen los borrados en cascada de las hijas.)
    if not exists (select 1 from public.groups where id = old.group_id) then
        return coalesce(new, old);
    end if;

    -- Trigger BEFORE: el cambio todavía no se ha aplicado, así que se excluye
    -- explícitamente la fila que se está tocando.
    select count(*) into quedan
    from public.group_members
    where group_id = old.group_id
      and role = 'owner'
      and user_id <> old.user_id;

    if quedan = 0 then
        raise exception
            'El grupo % se quedaría sin ningún propietario', old.group_id
            using errcode = 'check_violation',
                  hint = 'Nombra propietario a otro miembro antes de degradarte o salir del grupo.';
    end if;

    return coalesce(new, old);
end;
$$;

drop trigger if exists antes_de_perder_propietario on public.group_members;
create trigger antes_de_perder_propietario
    before update or delete on public.group_members
    for each row execute function public.proteger_ultimo_propietario();

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
-- El BACKFILL NO va aquí
--
-- Una versión anterior de este archivo proponía:
--
--     insert into group_members (...)
--     select ... from groups cross join profiles;
--
-- **Eso es incorrecto y se ha retirado.** Convertiría todos los grupos en
-- compartidos por todas las cuentas, y la regla de negocio es la contraria:
-- la pertenencia se define grupo a grupo. En cuanto exista una tercera
-- persona o un grupo individual, ese backfill daría acceso a datos ajenos.
--
-- El backfill real vive en `0002b_backfill_pertenencia.sql`, es explícito
-- grupo por grupo, y lo tiene que confirmar Dani antes de ejecutarse.
--
-- IMPORTANTE: este archivo y `0002b` deben aplicarse EN LA MISMA TRANSACCIÓN.
-- Entre uno y otro, `group_members` existe pero está vacía, y como la
-- pertenencia es la fuente de verdad, en ese instante nadie vería ningún
-- grupo:
--
--     psql "$URL" -v ON_ERROR_STOP=1 --single-transaction \
--       -f supabase/migrations/0002_group_members.sql \
--       -f supabase/migrations/0002b_backfill_pertenencia.sql
--
-- Ver docs/PLAN-MIGRACION-DATOS.md §3.
-- ============================================================
