-- ============================================================
-- 0007 · Trasladar saldo entre grupos
--
-- Mover una deuda de un grupo a otro SIN convertirla en gasto: un gasto
-- falso duplicaría el total gastado, el reparto por categoría y los
-- informes. Es una transferencia de deuda, no consumo.
--
-- Se apoya en que `settlements` ya codifica la dirección con `from_user` y
-- `to_user`, y en que `js/balances.js` la interpreta así:
--
--     from_user = yo,   to_user = otro  →  reduce lo que YO debo
--     from_user = otro, to_user = yo    →  reduce lo que me deben
--
-- De ahí salen los dos movimientos de un traslado:
--
--   ORIGEN   from_user = deudor,   to_user = acreedor  → salda la deuda allí
--   DESTINO  from_user = acreedor, to_user = deudor    → la crea aquí
--
-- La fila del destino va en dirección INVERSA a propósito. Por eso lleva
-- `transfer_role`: sin él, la lista de movimientos diría «pago de X a Y»,
-- que es justo lo contrario de lo que ha pasado.
--
-- Idempotente. Pensada para --single-transaction.
-- ============================================================

-- ── 1 · La transferencia ─────────────────────────────────────
create table if not exists public.balance_transfers (
    id              uuid primary key default gen_random_uuid(),
    grupo_origen    uuid not null references public.groups(id)   on delete cascade,
    grupo_destino   uuid not null references public.groups(id)   on delete cascade,
    deudor          uuid not null references public.profiles(id),
    acreedor        uuid not null references public.profiles(id),
    importe         numeric(12,2) not null,
    fecha           date not null default current_date,
    creado_por      uuid not null references public.profiles(id),
    created_at      timestamptz not null default now(),
    idempotency_key text not null,
    revertido_en    timestamptz,
    revertido_por   uuid references public.profiles(id),

    constraint ck_transfer_grupos_distintos   check (grupo_origen <> grupo_destino),
    constraint ck_transfer_personas_distintas check (deudor <> acreedor),
    constraint ck_transfer_importe_positivo   check (importe > 0)
);

comment on table public.balance_transfers is
    'Traslados de deuda entre grupos. NO son gastos: no cuentan en totales '
    'ni en estadísticas por categoría.';

create unique index if not exists uq_transfer_idempotency
    on public.balance_transfers (idempotency_key);

create index if not exists idx_transfer_origen  on public.balance_transfers (grupo_origen);
create index if not exists idx_transfer_destino on public.balance_transfers (grupo_destino);

-- ── 2 · El vínculo desde las liquidaciones ───────────────────
alter table public.settlements
    add column if not exists transfer_id uuid
        references public.balance_transfers(id) on delete cascade;

alter table public.settlements
    add column if not exists transfer_role text;

do $rol$
begin
    if not exists (select 1 from pg_constraint
                    where conname = 'ck_settlement_transfer_role'
                      and conrelid = 'public.settlements'::regclass) then
        alter table public.settlements
            add constraint ck_settlement_transfer_role check (
                transfer_role is null
                or transfer_role in ('origen','destino','reversion_origen','reversion_destino')
            );
    end if;

    -- Los dos campos van juntos o no van.
    if not exists (select 1 from pg_constraint
                    where conname = 'ck_settlement_transfer_par'
                      and conrelid = 'public.settlements'::regclass) then
        alter table public.settlements
            add constraint ck_settlement_transfer_par check (
                (transfer_id is null and transfer_role is null)
                or (transfer_id is not null and transfer_role is not null)
            );
    end if;
end
$rol$;

create index if not exists idx_settlements_transfer
    on public.settlements (transfer_id) where transfer_id is not null;

-- ── 3 · El saldo, calculado en el servidor ───────────────────
-- Réplica exacta de `js/balances.js`: se acumula en céntimos y se redondea
-- una sola vez. Signo: > 0 → `p_otro` debe a `p_yo`; < 0 → al revés.
--
-- El importe NUNCA se acepta del navegador. Si el cliente pudiera decir
-- cuánto trasladar, podría inventarse una deuda.
create or replace function public.saldo_centimos(
    p_grupo uuid, p_yo uuid, p_otro uuid
) returns bigint
language sql
stable
security invoker
set search_path = public
as $$
    -- floor(x + 0.5) y no round(): `round()` de PostgreSQL redondea medio
    -- hacia fuera de cero —round(-500.5) = -501— y `Math.round` de
    -- JavaScript medio hacia +inf —Math.round(-500.5) = -500—. Con un gasto
    -- de céntimos impares a medias (10,01 € → 500,5 céntimos) el servidor y
    -- la pantalla dirían cosas distintas, y un traslado «total» dejaría el
    -- origen con un céntimo colgando.
    select coalesce(floor(0.5 +
        coalesce((
            select sum(e.amount * 100 * (1 - e.payer_share)
                       * case when e.paid_by = p_yo   then  1
                              when e.paid_by = p_otro then -1
                              else 0 end)
              from public.expenses e where e.group_id = p_grupo
        ), 0)
        + coalesce((
            select sum(s.amount * 100
                       * case when s.from_user = p_yo   and s.to_user = p_otro then  1
                              when s.from_user = p_otro and s.to_user = p_yo   then -1
                              else 0 end)
              from public.settlements s where s.group_id = p_grupo
        ), 0)
    ), 0)::bigint;
$$;

comment on function public.saldo_centimos(uuid, uuid, uuid) is
    'Saldo en céntimos de p_yo frente a p_otro en un grupo. >0: p_otro le debe.';

revoke all on function public.saldo_centimos(uuid, uuid, uuid) from public;
grant execute on function public.saldo_centimos(uuid, uuid, uuid) to authenticated;

-- ── 4 · Las dos personas de un grupo PAR ─────────────────────
create or replace function public.pareja_del_grupo(p_grupo uuid)
returns uuid[]
language sql
stable
security invoker
set search_path = public
as $$
    select case when count(*) = 2
                then array_agg(m.user_id order by m.user_id)
                else null end
      from public.group_members m where m.group_id = p_grupo;
$$;

revoke all on function public.pareja_del_grupo(uuid) from public;
grant execute on function public.pareja_del_grupo(uuid) to authenticated;

-- ── 5 · Coherencia: media transferencia no puede existir ─────
-- Se comprueba al CONFIRMAR, no al insertar, porque la fila de la
-- transferencia se crea antes que sus dos liquidaciones. Diferida y como
-- constraint trigger: ni siquiera construyendo las filas a mano desde
-- PostgREST se puede dejar una mitad suelta.
create or replace function public.comprobar_traslado_coherente()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
    n_origen  integer;
    n_destino integer;
    imp_o     numeric;
    imp_d     numeric;
begin
    select count(*), coalesce(sum(amount), 0) into n_origen, imp_o
      from public.settlements
     where transfer_id = new.id and transfer_role = 'origen';

    select count(*), coalesce(sum(amount), 0) into n_destino, imp_d
      from public.settlements
     where transfer_id = new.id and transfer_role = 'destino';

    if n_origen <> 1 or n_destino <> 1 then
        raise exception 'Traslado incoherente: % movimiento(s) en origen y % en destino, deben ser 1 y 1',
                        n_origen, n_destino
            using errcode = 'integrity_constraint_violation';
    end if;

    if imp_o <> new.importe or imp_d <> new.importe then
        raise exception 'Traslado incoherente: importes % y % no coinciden con %',
                        imp_o, imp_d, new.importe
            using errcode = 'integrity_constraint_violation';
    end if;

    -- Y en la dirección correcta, o el saldo se movería al revés.
    if not exists (select 1 from public.settlements
                    where transfer_id = new.id and transfer_role = 'origen'
                      and group_id = new.grupo_origen
                      and from_user = new.deudor and to_user = new.acreedor) then
        raise exception 'Traslado incoherente: el movimiento de origen no salda la deuda'
            using errcode = 'integrity_constraint_violation';
    end if;

    if not exists (select 1 from public.settlements
                    where transfer_id = new.id and transfer_role = 'destino'
                      and group_id = new.grupo_destino
                      and from_user = new.acreedor and to_user = new.deudor) then
        raise exception 'Traslado incoherente: el movimiento de destino no crea la deuda'
            using errcode = 'integrity_constraint_violation';
    end if;

    return null;
end
$$;

drop trigger if exists tr_traslado_coherente on public.balance_transfers;
create constraint trigger tr_traslado_coherente
    after insert on public.balance_transfers
    deferrable initially deferred
    for each row execute function public.comprobar_traslado_coherente();

-- ── 6 · Las liquidaciones de un traslado no se tocan a mano ──
-- Editar o borrar una sola mitad descuadraría las dos deudas. Revertir no
-- borra: compensa con dos movimientos nuevos.
-- Solo las funciones de traslado pueden poner `transfer_id`, y solo ellas
-- pueden tocar una liquidación que ya lo tenga. Se distinguen con un ajuste
-- LOCAL de transacción que el cliente no puede fijar: `set_config` vive en
-- `pg_catalog`, PostgREST solo expone funciones del esquema público, y cada
-- petición suya es una transacción distinta.
--
-- Sin esto, con un simple POST a /rest/v1/settlements se podía enganchar una
-- tercera mitad a un traslado ajeno —dejándolo imposible de deshacer para
-- siempre— o marcar una liquidación cualquiera con `transfer_id` para que no
-- se pudiera editar ni borrar nunca más.
create or replace function public.proteger_liquidacion_de_traslado()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_permitido text := current_setting('app.traslado_en_curso', true);
    v_grupo     uuid;
begin
    if tg_op = 'INSERT' then
        if new.transfer_id is not null
           and coalesce(v_permitido, '') <> new.transfer_id::text then
            raise exception 'Una liquidación no se engancha a un traslado a mano'
                using hint = 'Usa public.trasladar_saldo(...).',
                      errcode = 'insufficient_privilege';
        end if;
        return new;
    end if;

    -- UPDATE y DELETE. Si el grupo ya no existe, esto es una cascada de
    -- `on delete cascade` al borrar el grupo: no se estorba, igual que hace
    -- `proteger_ultimo_propietario` en 0002.
    select id into v_grupo from public.groups where id = old.group_id;
    if v_grupo is null then
        return case when tg_op = 'DELETE' then old else new end;
    end if;

    -- Y si el traslado del que colgaba ya no existe, esto es la cascada de
    -- haber borrado ESE traslado —porque se borró uno de sus dos grupos—.
    -- La liquidación de la otra punta vive en un grupo que sigue ahí, así
    -- que la exención anterior no la cubría y el grupo quedaba imborrable.
    if tg_op = 'DELETE' and old.transfer_id is not null
       and not exists (select 1 from public.balance_transfers where id = old.transfer_id) then
        return old;
    end if;

    if coalesce(old.transfer_id, case when tg_op = 'UPDATE' then new.transfer_id end) is not null
       and coalesce(v_permitido, '') <> coalesce(old.transfer_id, new.transfer_id)::text then
        raise exception 'Esta liquidación forma parte de un traslado de saldo: no se edita ni se borra suelta'
            using hint = 'Usa public.revertir_traslado(id) para deshacerlo entero.',
                  errcode = 'insufficient_privilege';
    end if;

    return case when tg_op = 'DELETE' then old else new end;
end
$$;

drop trigger if exists tr_proteger_liquidacion_traslado on public.settlements;
create trigger tr_proteger_liquidacion_traslado
    before insert or update or delete on public.settlements
    for each row execute function public.proteger_liquidacion_de_traslado();

-- ── 6b · El traslado es un registro, no un formulario ────────
-- La política de UPDATE solo puede comprobar pertenencia; no puede comparar
-- NEW con OLD. Sin este trigger, un miembro podía cambiar el importe o los
-- grupos con un PATCH y volver a poner `revertido_en` a NULL, y luego usar
-- `revertir_traslado` para inyectar liquidaciones por el importe que
-- quisiera. Aquí solo se admite marcarlo revertido, y una sola vez.
create or replace function public.proteger_traslado()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
    if (new.id, new.grupo_origen, new.grupo_destino, new.deudor, new.acreedor,
        new.importe, new.fecha, new.creado_por, new.created_at, new.idempotency_key)
       is distinct from
       (old.id, old.grupo_origen, old.grupo_destino, old.deudor, old.acreedor,
        old.importe, old.fecha, old.creado_por, old.created_at, old.idempotency_key)
    then
        raise exception 'Un traslado no se modifica: solo se puede deshacer'
            using errcode = 'insufficient_privilege';
    end if;

    if old.revertido_en is not null and new.revertido_en is null then
        raise exception 'Un traslado revertido no se puede «des-revertir»'
            using errcode = 'insufficient_privilege';
    end if;

    return new;
end
$$;

drop trigger if exists tr_proteger_traslado on public.balance_transfers;
create trigger tr_proteger_traslado
    before update on public.balance_transfers
    for each row execute function public.proteger_traslado();

-- ── 7 · La operación ─────────────────────────────────────────
-- `security invoker` a propósito: la RLS se sigue evaluando y la función no
-- puede convertirse en puerta trasera. Las comprobaciones explícitas están
-- para dar un mensaje claro, no para sustituir a la RLS.
create or replace function public.trasladar_saldo(
    p_grupo_origen    uuid,
    p_grupo_destino   uuid,
    p_idempotency_key text,
    p_importe         numeric default null   -- null = todo el saldo
) returns public.balance_transfers
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_actor    uuid := auth.uid();
    v_previo   public.balance_transfers;
    v_pareja_o uuid[];
    v_pareja_d uuid[];
    v_a        uuid;
    v_b        uuid;
    v_saldo    bigint;
    v_deudor   uuid;
    v_acreedor uuid;
    v_cent     bigint;
    v_importe  numeric(12,2);
    v_t        public.balance_transfers;
begin
    if v_actor is null then
        raise exception 'No hay sesión' using errcode = 'insufficient_privilege';
    end if;
    if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
        raise exception 'Falta la clave de idempotencia' using errcode = 'invalid_parameter_value';
    end if;

    -- 1 · Idempotencia lo primero: un reintento por mala conexión no puede
    --     trasladar dos veces. La comprobación de verdad va abajo, con
    --     `on conflict`: mirar aquí y actuar después es comprobar-luego-actuar,
    --     y dos llamadas simultáneas con la misma clave pasarían las dos.
    --     Esta lectura solo sirve para el camino rápido.
    select * into v_previo from public.balance_transfers
     where idempotency_key = p_idempotency_key;
    if found then
        if v_previo.grupo_origen <> p_grupo_origen
           or v_previo.grupo_destino <> p_grupo_destino
           or (p_importe is not null and v_previo.importe <> round(p_importe, 2)) then
            raise exception 'Esa clave de idempotencia ya se usó para otro traslado distinto'
                using errcode = 'invalid_parameter_value';
        end if;
        return v_previo;
    end if;

    if p_grupo_origen = p_grupo_destino then
        raise exception 'El grupo de destino no puede ser el mismo que el de origen'
            using errcode = 'invalid_parameter_value';
    end if;

    -- 2 · Autorización explícita, además de la RLS.
    if not public.es_miembro(p_grupo_origen) or not public.es_miembro(p_grupo_destino) then
        raise exception 'No perteneces a los dos grupos' using errcode = 'insufficient_privilege';
    end if;

    -- 3 · Serialización. Siempre en el mismo orden, o dos traslados
    --     simultáneos podrían llevarse el saldo dos veces.
    -- Dos bloqueos de un argumento, siempre en el mismo orden: la variante de
    -- dos argumentos es (int,int) y no acepta bigint, y un solo bloqueo sobre
    -- el par dejaría escapar dos traslados que compartan un grupo.
    perform pg_advisory_xact_lock(
        hashtextextended(least(p_grupo_origen, p_grupo_destino)::text, 0));
    perform pg_advisory_xact_lock(
        hashtextextended(greatest(p_grupo_origen, p_grupo_destino)::text, 0));

    -- 4 · Las mismas dos personas en los dos grupos.
    v_pareja_o := public.pareja_del_grupo(p_grupo_origen);
    v_pareja_d := public.pareja_del_grupo(p_grupo_destino);
    if v_pareja_o is null then
        raise exception 'El grupo de origen no tiene exactamente dos participantes'
            using hint = 'El traslado de saldo solo existe entre dos personas.',
                  errcode = 'invalid_parameter_value';
    end if;
    if v_pareja_d is null then
        raise exception 'El grupo de destino no tiene exactamente dos participantes'
            using errcode = 'invalid_parameter_value';
    end if;
    if v_pareja_o <> v_pareja_d then
        raise exception 'Los dos grupos no tienen a las mismas dos personas'
            using errcode = 'invalid_parameter_value';
    end if;

    v_a := v_pareja_o[1];
    v_b := v_pareja_o[2];

    -- 5 · El saldo se calcula AQUÍ. Nunca se acepta del navegador.
    v_saldo := public.saldo_centimos(p_grupo_origen, v_a, v_b);
    if v_saldo = 0 then
        raise exception 'El grupo de origen está saldado: no hay nada que trasladar'
            using errcode = 'invalid_parameter_value';
    end if;

    -- 6 · Quién debe a quién. saldo > 0 → v_b debe a v_a.
    if v_saldo > 0 then
        v_deudor := v_b; v_acreedor := v_a; v_cent := v_saldo;
    else
        v_deudor := v_a; v_acreedor := v_b; v_cent := -v_saldo;
    end if;

    -- 7 · Total o parcial, nunca más de lo que se debe.
    if p_importe is null then
        v_importe := round(v_cent::numeric / 100, 2);
    else
        v_importe := round(p_importe, 2);
        if v_importe <= 0 then
            raise exception 'El importe a trasladar tiene que ser mayor que cero'
                using errcode = 'invalid_parameter_value';
        end if;
        if round(v_importe * 100) > v_cent then
            raise exception 'No se puede trasladar % €: la deuda del grupo es de % €',
                            v_importe, round(v_cent::numeric / 100, 2)
                using errcode = 'invalid_parameter_value';
        end if;
    end if;

    -- 8 · Deudor y acreedor tienen que estar en el destino. Ya se ha
    --     comprobado que la pareja es la misma, pero se deja explícito.
    if not public.es_miembro(p_grupo_destino, v_deudor)
       or not public.es_miembro(p_grupo_destino, v_acreedor) then
        raise exception 'Las dos personas tienen que pertenecer al grupo de destino'
            using errcode = 'invalid_parameter_value';
    end if;

    -- 9 · La transferencia y sus dos movimientos, en la misma transacción.
    insert into public.balance_transfers
        (grupo_origen, grupo_destino, deudor, acreedor, importe, creado_por, idempotency_key)
    values (p_grupo_origen, p_grupo_destino, v_deudor, v_acreedor, v_importe,
            v_actor, p_idempotency_key)
    on conflict (idempotency_key) do nothing
    returning * into v_t;

    -- Si otra llamada simultánea se adelantó, no es un error: es el mismo
    -- traslado. Devolverlo es lo que hace que un reintento sea inocuo, en
    -- vez de un 23505 que el cliente interpretaría como fallo.
    if v_t.id is null then
        select * into v_t from public.balance_transfers
         where idempotency_key = p_idempotency_key;
        if not found then
            raise exception 'No se ha podido registrar el traslado'
                using errcode = 'integrity_constraint_violation';
        end if;
        return v_t;
    end if;

    -- A partir de aquí, y solo dentro de esta transacción, se permite poner
    -- `transfer_id` en las liquidaciones. El trigger lo exige.
    perform set_config('app.traslado_en_curso', v_t.id::text, true);

    -- ORIGEN: el deudor «paga» al acreedor → la deuda de allí baja.
    insert into public.settlements
        (group_id, from_user, to_user, amount, note, settled_on, client_id,
         transfer_id, transfer_role)
    values (p_grupo_origen, v_deudor, v_acreedor, v_importe,
            'Saldo trasladado a otro grupo', current_date,
            'traslado-o-' || v_t.id::text, v_t.id, 'origen');

    -- DESTINO: en dirección inversa → la deuda aparece aquí.
    insert into public.settlements
        (group_id, from_user, to_user, amount, note, settled_on, client_id,
         transfer_id, transfer_role)
    values (p_grupo_destino, v_acreedor, v_deudor, v_importe,
            'Saldo procedente de otro grupo', current_date,
            'traslado-d-' || v_t.id::text, v_t.id, 'destino');

    -- 10 · El origen no puede quedar con la deuda invertida. El saldo se lee
    --      con el bloqueo tomado, pero apuntar un gasto NO toma ese bloqueo,
    --      así que entre el cálculo y el apunte la otra persona podría haber
    --      cambiado el grupo. Si eso ha pasado, se deshace todo.
    v_saldo := public.saldo_centimos(p_grupo_origen, v_deudor, v_acreedor);
    if v_saldo > 0 then
        raise exception 'El saldo del grupo de origen ha cambiado mientras se trasladaba: reinténtalo'
            using errcode = 'serialization_failure';
    end if;

    perform set_config('app.traslado_en_curso', '', true);
    return v_t;
end
$$;

revoke all on function public.trasladar_saldo(uuid, uuid, text, numeric) from public;
grant execute on function public.trasladar_saldo(uuid, uuid, text, numeric) to authenticated;

comment on function public.trasladar_saldo(uuid, uuid, text, numeric) is
    'Traslada deuda de un grupo a otro. El importe se calcula en el servidor; '
    'p_importe permite trasladar solo una parte. Idempotente por clave.';

-- ── 8 · Deshacer ─────────────────────────────────────────────
-- No borra nada: compensa. Así queda el rastro completo de lo que pasó.
create or replace function public.revertir_traslado(p_transfer_id uuid)
returns public.balance_transfers
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_actor uuid := auth.uid();
    v_t     public.balance_transfers;
    n       integer;
begin
    if v_actor is null then
        raise exception 'No hay sesión' using errcode = 'insufficient_privilege';
    end if;

    select * into v_t from public.balance_transfers where id = p_transfer_id for update;
    if not found then
        raise exception 'Ese traslado no existe' using errcode = 'no_data_found';
    end if;
    if v_t.revertido_en is not null then
        return v_t;   -- idempotente: deshacer dos veces no hace nada nuevo
    end if;

    if not public.es_miembro(v_t.grupo_origen) or not public.es_miembro(v_t.grupo_destino) then
        raise exception 'No perteneces a los dos grupos' using errcode = 'insufficient_privilege';
    end if;

    -- Solo si sus dos movimientos siguen enteros.
    select count(*) into n from public.settlements
     where transfer_id = v_t.id and transfer_role in ('origen','destino');
    if n <> 2 then
        raise exception 'No se puede deshacer: faltan movimientos del traslado (% de 2)', n
            using errcode = 'integrity_constraint_violation';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(least(v_t.grupo_origen, v_t.grupo_destino)::text, 0));
    perform pg_advisory_xact_lock(
        hashtextextended(greatest(v_t.grupo_origen, v_t.grupo_destino)::text, 0));

    perform set_config('app.traslado_en_curso', v_t.id::text, true);

    insert into public.settlements
        (group_id, from_user, to_user, amount, note, settled_on, client_id,
         transfer_id, transfer_role)
    values (v_t.grupo_origen, v_t.acreedor, v_t.deudor, v_t.importe,
            'Traslado deshecho', current_date,
            'traslado-ro-' || v_t.id::text, v_t.id, 'reversion_origen');

    insert into public.settlements
        (group_id, from_user, to_user, amount, note, settled_on, client_id,
         transfer_id, transfer_role)
    values (v_t.grupo_destino, v_t.deudor, v_t.acreedor, v_t.importe,
            'Traslado deshecho', current_date,
            'traslado-rd-' || v_t.id::text, v_t.id, 'reversion_destino');

    update public.balance_transfers
       set revertido_en = now(), revertido_por = v_actor
     where id = v_t.id
    returning * into v_t;

    perform set_config('app.traslado_en_curso', '', true);
    return v_t;
end
$$;

revoke all on function public.revertir_traslado(uuid) from public;
grant execute on function public.revertir_traslado(uuid) to authenticated;

-- ── 9 · RLS de la tabla de traslados ─────────────────────────
alter table public.balance_transfers enable row level security;
revoke all on public.balance_transfers from anon;
revoke all on public.balance_transfers from authenticated;
grant select, insert, update on public.balance_transfers to authenticated;

drop policy if exists traslados_leer      on public.balance_transfers;
drop policy if exists traslados_crear     on public.balance_transfers;
drop policy if exists traslados_revertir  on public.balance_transfers;

-- Se ve si perteneces a cualquiera de los dos grupos: la mitad que te toca
-- explica un movimiento que ves en tu lista.
create policy traslados_leer on public.balance_transfers
    for select to authenticated
    using (public.es_miembro(grupo_origen) or public.es_miembro(grupo_destino));

-- Crear exige pertenecer a LOS DOS y firmarlo con tu propia identidad, así
-- que desde el cliente no se puede fabricar un traslado ajeno.
create policy traslados_crear on public.balance_transfers
    for insert to authenticated
    with check (
        public.es_miembro(grupo_origen)
        and public.es_miembro(grupo_destino)
        and creado_por = auth.uid()
        and public.es_miembro(grupo_origen, deudor)
        and public.es_miembro(grupo_origen, acreedor)
        and public.es_miembro(grupo_destino, deudor)
        and public.es_miembro(grupo_destino, acreedor)
    );

-- Solo para marcarlo revertido. Sin DELETE: los traslados no se borran.
create policy traslados_revertir on public.balance_transfers
    for update to authenticated
    using (public.es_miembro(grupo_origen) and public.es_miembro(grupo_destino))
    with check (public.es_miembro(grupo_origen) and public.es_miembro(grupo_destino));

-- ── 10 · Comprobación final ──────────────────────────────────
do $final$
declare
    n integer;
begin
    if to_regclass('public.balance_transfers') is null then
        raise exception 'No se ha creado balance_transfers';
    end if;
    select count(*) into n from pg_policies
     where schemaname='public' and tablename='balance_transfers';
    if n <> 3 then
        raise exception 'balance_transfers tiene % políticas, se esperaban 3', n;
    end if;
    if not exists (select 1 from pg_tables where schemaname='public'
                    and tablename='balance_transfers' and rowsecurity) then
        raise exception 'balance_transfers no tiene RLS activa';
    end if;
    if exists (select 1 from pg_policies where schemaname='public'
                and tablename='balance_transfers' and cmd='DELETE') then
        raise exception 'balance_transfers no debe tener política de DELETE';
    end if;
    raise notice 'Traslado de saldo instalado: tabla, 3 políticas, dos triggers de coherencia y las funciones';
end
$final$;
