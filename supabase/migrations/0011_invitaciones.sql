-- ============================================================
-- 0011 · Invitaciones por enlace
--
-- Un miembro genera un enlace y lo comparte por donde quiera. Quien lo abre
-- entra en el grupo, y solo en ese grupo. Sin correo, sin proveedor externo,
-- sin infraestructura nueva.
--
-- Este archivo es SOLO EL SERVIDOR. No hay interfaz todavía (F2).
--
-- No toca datos existentes. No toca `expenses`, `settlements` ni
-- `balance_transfers`. Los grupos que ya existen no cambian en nada: nadie
-- entra ni sale, y ningún saldo se recalcula.
--
-- Es idempotente.
--
-- ── Cómo se protege el enlace ────────────────────────────────
--
-- El token son 32 bytes aleatorios en base64url (43 caracteres). En la base
-- de datos se guarda EXCLUSIVAMENTE su SHA-256: quien lea la tabla —copia,
-- volcado, respaldo— no obtiene ni un enlace que funcione.
--
-- Se genera en el SERVIDOR, y `crear_invitacion()` lo devuelve UNA sola vez.
-- Es mejor que generarlo en el navegador por dos razones concretas:
--   · la calidad del azar no depende del dispositivo de quien invita;
--   · al crear, el token viaja solo en la RESPUESTA, nunca como parámetro de
--     una consulta, así que no puede acabar en el registro de sentencias.
-- F2 no necesita ningún cambio aquí: recibe el token y construye la URL.
--
-- El token NO se deriva del grupo ni de la persona: del enlace no se puede
-- sacar ningún UUID.
-- ============================================================

-- ------------------------------------------------------------
-- La tabla
-- ------------------------------------------------------------
create table if not exists public.group_invitations (
    id            uuid primary key default gen_random_uuid(),
    group_id      uuid not null references public.groups(id)   on delete cascade,
    creada_por    uuid not null references public.profiles(id) on delete cascade,

    -- SHA-256 del token. 32 bytes. Nunca el token en claro.
    token_hash    bytea not null,

    creada_en     timestamptz not null default now(),
    caduca_en     timestamptz not null,
    revocada_en   timestamptz,
    revocada_por  uuid references public.profiles(id) on delete set null,

    -- `null` = usos ilimitados mientras no se revoque, que es lo acordado por
    -- defecto. La columna existe desde el principio para que poner un límite
    -- más adelante no obligue a rediseñar nada.
    max_usos      integer,
    usos          integer not null default 0,
    ultimo_uso_en timestamptz,

    constraint uq_invitaciones_token   unique (token_hash),
    constraint ck_invitaciones_hash    check (octet_length(token_hash) = 32),
    constraint ck_invitaciones_usos    check (usos >= 0),
    constraint ck_invitaciones_maximo  check (max_usos is null or max_usos >= 1),
    constraint ck_invitaciones_ventana check (caduca_en > creada_en)
);

create index if not exists idx_invitaciones_grupo on public.group_invitations(group_id);

-- ------------------------------------------------------------
-- Privilegios de tabla
--
-- `authenticated` solo puede LEER, y ni siquiera todas las columnas:
-- `token_hash` queda fuera del grant. No es que sirviera de mucho tenerlo
-- —es un SHA-256 de 244 bits de entropía, no se invierte— pero no hay
-- ninguna razón para enseñarlo, y el privilegio por columnas lo impide antes
-- de que RLS entre siquiera en juego.
--
-- Crear, revocar y aceptar pasan EXCLUSIVAMENTE por las funciones de abajo.
-- Por eso no hay grant de insert, update ni delete, y tampoco políticas para
-- esas tres operaciones: con RLS activa, lo que no tiene política se deniega.
-- ------------------------------------------------------------
alter table public.group_invitations enable row level security;

revoke all on public.group_invitations from anon, authenticated;
grant select (id, group_id, creada_por, creada_en, caduca_en,
              revocada_en, revocada_por, max_usos, usos, ultimo_uso_en)
    on public.group_invitations to authenticated;

-- Los miembros del grupo ven las invitaciones de SU grupo, para poder
-- revocarlas. Nadie más las ve.
drop policy if exists invitaciones_leer on public.group_invitations;
create policy invitaciones_leer on public.group_invitations
    for select to authenticated
    using (public.es_miembro(group_id));

-- ============================================================
-- 1 · Crear
--
--   crear_invitacion(grupo, días = 7, max_usos = null) → token en claro
--
-- Devuelve el token UNA vez. No se puede recuperar después: si se pierde, se
-- genera otro y se revoca el anterior.
--
-- Quién puede: cualquier MIEMBRO del grupo. Es lo mismo que permitía la
-- política que 0010 retiró, así que no amplía capacidades de nadie.
-- Restringirlo a `owner` es cambiar una línea, marcada abajo.
-- ============================================================
create or replace function public.crear_invitacion(
    p_group_id uuid,
    p_dias     integer default 7,
    p_max_usos integer default null
)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
    v_yo    uuid := auth.uid();
    v_bytes bytea;
    v_token text;
begin
    if v_yo is null then
        raise exception 'No hay sesión' using errcode = 'insufficient_privilege';
    end if;

    -- ← Aquí se restringiría a propietarios: `and role = 'owner'`.
    if not exists (select 1 from public.group_members
                    where group_id = p_group_id and user_id = v_yo) then
        -- El mismo mensaje que si el grupo no existiera: no se confirma su
        -- existencia a quien no pertenece.
        raise exception 'No perteneces a ese grupo' using errcode = 'insufficient_privilege';
    end if;

    if p_dias is null or p_dias < 1 or p_dias > 90 then
        raise exception 'La caducidad tiene que estar entre 1 y 90 días'
            using errcode = 'check_violation';
    end if;
    if p_max_usos is not null and p_max_usos < 1 then
        raise exception 'El límite de usos tiene que ser 1 o más'
            using errcode = 'check_violation';
    end if;

    -- 32 bytes de dos `gen_random_uuid()`. En PostgreSQL 13+ es nativa y se
    -- apoya en `pg_strong_random()`, la misma fuente que usa el servidor para
    -- material criptográfico. Cada UUID aporta 122 bits, así que son 244 bits
    -- de entropía: muy por encima de los 128 que se piden a un token.
    --
    -- No se usa `gen_random_bytes()` a propósito: es de pgcrypto, y este
    -- repositorio evita instalar pgcrypto (ver el comentario de 0001).
    v_bytes := decode(
        replace(gen_random_uuid()::text, '-', '') ||
        replace(gen_random_uuid()::text, '-', ''), 'hex');

    -- base64url: sin `+`, sin `/` y sin relleno, para que quepa tal cual en
    -- una URL y en un mensaje de WhatsApp sin que nada lo reescriba.
    v_token := translate(
        rtrim(replace(encode(v_bytes, 'base64'), E'\n', ''), '='),
        '+/', '-_');

    insert into public.group_invitations
        (group_id, creada_por, token_hash, caduca_en, max_usos)
    values
        (p_group_id, v_yo, sha256(convert_to(v_token, 'UTF8')),
         now() + make_interval(days => p_dias), p_max_usos);

    return v_token;
end;
$$;

-- ------------------------------------------------------------
-- El estado de una invitación, en un solo sitio
--
-- La usan `ver_invitacion` y `aceptar_invitacion`, y tienen que coincidir:
-- que una diga «válida» y la otra la rechace sería un fallo silencioso.
--
-- No se concede a nadie: es interna. Las dos funciones que la llaman son
-- SECURITY DEFINER y se ejecutan como su dueño, así que pueden invocarla
-- aunque `authenticated` no pueda.
--
-- STABLE, no IMMUTABLE: el `case` mira `now()` para decidir si la invitación
-- está caducada, y `now()` es la hora de la TRANSACCIÓN —estable dentro de
-- una consulta, distinta entre transacciones—. Declararla IMMUTABLE sería
-- mentir al planificador, que entonces puede plegar el resultado en tiempo
-- de planificación; como la función está en el camino de autorización de
-- `ver_invitacion()` y `aceptar_invitacion()`, una invitación caducada
-- podría seguir viéndose «valida». La comprobación de catálogo de abajo lo
-- impide volver a romper.
-- ------------------------------------------------------------
create or replace function public.estado_invitacion(p_inv public.group_invitations)
returns text
language sql
stable
as $$
    select case
        when p_inv.revocada_en is not null                        then 'revocada'
        when p_inv.caduca_en <= now()                             then 'caducada'
        when p_inv.max_usos is not null
             and p_inv.usos >= p_inv.max_usos                     then 'agotada'
        else 'valida'
    end;
$$;

-- ============================================================
-- 2 · Ver
--
--   ver_invitacion(token) → estado, grupo, quién invita, caducidad, si ya estoy
--
-- Lo MÍNIMO para decidir si aceptas. No devuelve el UUID del grupo, ni los
-- miembros, ni gastos, ni saldos, ni el correo de nadie.
--
-- El nombre del grupo solo se enseña si la invitación es VÁLIDA. Un enlace
-- caducado o revocado que acabe en malas manos no llega a decir a qué grupo
-- pertenecía.
-- ============================================================
create or replace function public.ver_invitacion(p_token text)
returns table (
    estado         text,
    grupo          text,
    invita         text,
    caduca_en      timestamptz,
    ya_soy_miembro boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_yo  uuid := auth.uid();
    v_inv public.group_invitations;
    v_est text;
begin
    if v_yo is null then
        raise exception 'No hay sesión' using errcode = 'insufficient_privilege';
    end if;

    -- Formato antes que nada: así una cadena arbitraria ni llega a la tabla.
    if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then
        return query select 'desconocida'::text, null::text, null::text,
                            null::timestamptz, false;
        return;
    end if;

    select * into v_inv from public.group_invitations
     where token_hash = sha256(convert_to(p_token, 'UTF8'));

    if not found then
        return query select 'desconocida'::text, null::text, null::text,
                            null::timestamptz, false;
        return;
    end if;

    v_est := public.estado_invitacion(v_inv);

    if v_est <> 'valida' then
        -- Se dice QUÉ le pasa, no A QUÉ grupo pertenecía.
        return query select v_est, null::text, null::text, null::timestamptz,
                            exists (select 1 from public.group_members
                                     where group_id = v_inv.group_id and user_id = v_yo);
        return;
    end if;

    return query
        select v_est,
               g.name,
               p.display_name,
               v_inv.caduca_en,
               exists (select 1 from public.group_members
                        where group_id = v_inv.group_id and user_id = v_yo)
          from public.groups g
          left join public.profiles p on p.id = v_inv.creada_por
         where g.id = v_inv.group_id;
end;
$$;

-- ============================================================
-- 3 · Aceptar
--
--   aceptar_invitacion(token) → resultado, group_id, nombre del grupo
--
-- LA FIRMA TIENE UN SOLO ARGUMENTO, y es deliberado: no hay ningún parámetro
-- `user_id` que el cliente pueda rellenar. Quien entra es `auth.uid()` y no
-- puede ser nadie más. No es una comprobación que se pueda olvidar: es que no
-- existe la forma de expresarlo.
--
-- Atomicidad y carreras: `for update` bloquea la fila de la invitación, así
-- que dos aceptaciones simultáneas del mismo enlace se serializan. La
-- segunda vuelve a leer `usos` ya incrementado, y si había límite ve
-- «agotada». Sin el bloqueo, dos peticiones a la vez podrían pasar las dos
-- por un `max_usos = 1`.
--
-- Idempotencia: si ya eres miembro no se duplica la fila ni se toca el
-- contador, y se devuelve el grupo igual, para que la interfaz pueda llevarte
-- allí en vez de enseñar un error.
--
-- `resultado` ∈ aceptada · ya_eras_miembro · caducada · revocada · agotada
--              · desconocida
-- ============================================================
create or replace function public.aceptar_invitacion(p_token text)
returns table (resultado text, grupo_id uuid, grupo text)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
    v_yo    uuid := auth.uid();
    v_inv   public.group_invitations;
    v_est   text;
    v_filas integer;
    v_nueva boolean;
begin
    if v_yo is null then
        raise exception 'No hay sesión' using errcode = 'insufficient_privilege';
    end if;

    if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then
        return query select 'desconocida'::text, null::uuid, null::text;
        return;
    end if;

    select * into v_inv from public.group_invitations
     where token_hash = sha256(convert_to(p_token, 'UTF8'))
     for update;

    if not found then
        return query select 'desconocida'::text, null::uuid, null::text;
        return;
    end if;

    -- Ya soy miembro: se resuelve ANTES de mirar caducidad. Volver a abrir un
    -- enlace viejo del grupo en el que ya estás no debe dar un error.
    if exists (select 1 from public.group_members m
                where m.group_id = v_inv.group_id and m.user_id = v_yo) then
        return query select 'ya_eras_miembro'::text, v_inv.group_id,
                            (select name from public.groups where id = v_inv.group_id);
        return;
    end if;

    v_est := public.estado_invitacion(v_inv);
    if v_est <> 'valida' then
        return query select v_est, null::uuid, null::text;
        return;
    end if;

    -- Alta. `on conflict do nothing` evita el comprobar-y-luego-actuar: si
    -- entre la comprobación de arriba y esta línea alguien hubiera insertado
    -- la fila, no se rompe nada y `v_nueva` sale falso.
    insert into public.group_members (group_id, user_id, role)
    values (v_inv.group_id, v_yo, 'member')
    on conflict (group_id, user_id) do nothing;

    get diagnostics v_filas = row_count;
    v_nueva := v_filas > 0;

    -- El contador solo sube cuando ha entrado alguien de verdad.
    if v_nueva then
        update public.group_invitations
           set usos = usos + 1, ultimo_uso_en = now()
         where id = v_inv.id;
    end if;

    return query select case when v_nueva then 'aceptada' else 'ya_eras_miembro' end,
                        v_inv.group_id,
                        (select name from public.groups where id = v_inv.group_id);
end;
$$;

-- ============================================================
-- 4 · Revocar
--
--   revocar_invitacion(id) → true si esta llamada la ha revocado
--
-- Puede revocar quien la creó o cualquier propietario del grupo. Devuelve
-- `false` para todo lo demás —no existe, no es tuya, ya estaba revocada— sin
-- distinguir entre esos casos: así el identificador de una invitación ajena
-- no confirma nada.
-- ============================================================
create or replace function public.revocar_invitacion(p_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
    v_yo  uuid := auth.uid();
    v_inv public.group_invitations;
begin
    if v_yo is null then
        raise exception 'No hay sesión' using errcode = 'insufficient_privilege';
    end if;
    if p_id is null then return false; end if;

    select * into v_inv from public.group_invitations where id = p_id for update;
    if not found then return false; end if;
    if v_inv.revocada_en is not null then return false; end if;

    if v_inv.creada_por <> v_yo
       and not exists (select 1 from public.group_members
                        where group_id = v_inv.group_id
                          and user_id = v_yo and role = 'owner') then
        return false;
    end if;

    update public.group_invitations
       set revocada_en = now(), revocada_por = v_yo
     where id = p_id;

    return true;
end;
$$;

-- ------------------------------------------------------------
-- Privilegios de las funciones · la regla de tres líneas de SECURITY.md
--
-- `estado_invitacion` NO se concede a nadie: es interna, y sus dos únicas
-- llamantes son SECURITY DEFINER.
--
-- Ninguna se concede a `anon`. Un enlace en manos de quien no ha iniciado
-- sesión no revela absolutamente nada hasta que entre o cree su cuenta.
-- ------------------------------------------------------------
revoke all on function public.crear_invitacion(uuid, integer, integer) from public, anon;
revoke all on function public.ver_invitacion(text)                     from public, anon;
revoke all on function public.aceptar_invitacion(text)                 from public, anon;
revoke all on function public.revocar_invitacion(uuid)                 from public, anon;
revoke all on function public.estado_invitacion(public.group_invitations)
    from public, anon, authenticated;

grant execute on function public.crear_invitacion(uuid, integer, integer) to authenticated;
grant execute on function public.ver_invitacion(text)                     to authenticated;
grant execute on function public.aceptar_invitacion(text)                 to authenticated;
grant execute on function public.revocar_invitacion(uuid)                 to authenticated;

-- ------------------------------------------------------------
-- Comprobación dentro de la propia migración
-- ------------------------------------------------------------
do $comprobar$
declare
    n integer;
    v_vol text;
begin
    if to_regclass('public.group_invitations') is null then
        raise exception '0011: no existe group_invitations';
    end if;

    -- estado_invitacion() mira now(): tiene que ser STABLE, nunca IMMUTABLE.
    select p.provolatile::text into v_vol
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = 'estado_invitacion';
    if v_vol is distinct from 's' then
        raise exception
            '0011: estado_invitacion debe ser STABLE y su provolatile es «%»', v_vol;
    end if;

    if has_column_privilege('authenticated', 'public.group_invitations', 'token_hash', 'select') then
        raise exception '0011: authenticated puede leer token_hash';
    end if;
    if has_table_privilege('authenticated', 'public.group_invitations', 'insert')
       or has_table_privilege('authenticated', 'public.group_invitations', 'update')
       or has_table_privilege('authenticated', 'public.group_invitations', 'delete') then
        raise exception '0011: authenticated puede escribir en group_invitations';
    end if;

    -- La firma de aceptar_invitacion tiene que tener UN solo argumento.
    select pronargs into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = 'aceptar_invitacion';
    if n <> 1 then
        raise exception '0011: aceptar_invitacion tiene % argumentos y debe tener 1', n;
    end if;

    raise notice 'Invitaciones instaladas: crear, ver, aceptar y revocar.';
    raise notice 'Por defecto 7 días y usos ilimitados hasta revocar.';
end
$comprobar$;
