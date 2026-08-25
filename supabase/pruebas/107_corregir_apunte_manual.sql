-- ============================================================
-- Corrección del apunte manual «Deuda Dani225,60» · UNA transacción
--
-- NO EJECUTAR SIN AUTORIZACIÓN EXPRESA DE DANI.
--
-- Qué hace, y por qué en una sola transacción: el apunte manual fue el apaño
-- para trasladar a mano la deuda de Slovenia, y es un GASTO. Contarlo y
-- además ejecutar el traslado real contaría la deuda dos veces. Borrarlo y
-- trasladar tienen que entrar juntos o no entrar: si se quedara a medias,
-- Bierzo perdería la deuda entera o la tendría duplicada.
--
-- Cada condición se comprueba con los números exactos del diagnóstico. Si UNA
-- sola falla, la transacción se deshace completa y no cambia nada.
--
-- No imprime UUID, correos, URI, notas ni conceptos ajenos.
--
--     psql "$URL" -v ON_ERROR_STOP=1 --single-transaction \
--          -f supabase/pruebas/107_corregir_apunte_manual.sql
-- ============================================================
\set ON_ERROR_STOP on

do $corregir$
declare
    -- Los números del diagnóstico, en céntimos.
    C_GASTO        constant bigint := 45120;   -- 451,20 € almacenados
    C_SLOVENIA     constant bigint := -22559;  -- laurel debe 225,59
    C_BIERZO_ANTES constant bigint := -15610;  -- laurel debe 156,10
    C_BIERZO_MEDIO constant bigint := 6950;    -- tras borrar el apunte falso
    C_BIERZO_FIN   constant bigint := -15609;  -- tras trasladar
    C_TOTAL_ANTES  constant bigint := 59020;
    -- 59.020 − 45.120 = 13.900. El primer borrador ponía 36.460, que sale de
    -- restar la DEUDA que genera el gasto (225,60) en vez de su importe
    -- ALMACENADO (451,20). `total gastado` suma `amount`, no
    -- `amount × reparto`: al borrar la fila desaparecen los 451,20 enteros.
    -- El ensayo lo cazó antes de tocar producción; Dani lo ha confirmado.
    C_TOTAL_FIN    constant bigint := 13900;
    CONCEPTO       constant text   := 'Deuda Dani225,60';
    RESORTE        constant text   := 'c0b47a8b';
    CLAVE          constant text   := 'correccion-apunte-manual-2026-08-25';

    g_slovenia uuid;
    g_bierzo   uuid;
    laurel     uuid;
    buganvilla uuid;
    el_gasto   uuid;
    n          bigint;
    s_o        bigint;
    s_d        bigint;
    total      bigint;
    t          public.balance_transfers;
begin
    -- ── 0 · Sesión y grupos ──────────────────────────────────
    select id into g_slovenia from public.groups where name = 'Slovenia';
    select id into g_bierzo   from public.groups where name = 'Bierzo & Asturias';
    if g_slovenia is null or g_bierzo is null then
        raise exception 'No encuentro los dos grupos';
    end if;

    select id into laurel     from public.profiles where color = 'laurel';
    select id into buganvilla from public.profiles where color = 'buganvilla';
    if laurel is null or buganvilla is null then
        raise exception 'No encuentro los dos perfiles por color';
    end if;

    -- `trasladar_saldo` es `security invoker` y exige `auth.uid()`: sin
    -- sesión rechaza con «No hay sesión». Se suplanta a `laurel` —la persona
    -- cuya deuda se traslada, y miembro de los dos grupos—, igual que hacen
    -- las pruebas del banco. La suplantación es LOCAL a esta transacción.
    perform set_config('request.jwt.claims',
                       json_build_object('sub', laurel)::text, true);
    if auth.uid() is null then
        raise exception 'No se ha podido fijar la sesión'
            using errcode = 'insufficient_privilege';
    end if;

    -- ── 1 · Bloquear y volver a localizar el gasto ───────────
    -- Por su identidad real —resorte del id—, no solo por el concepto: dos
    -- gastos podrían llamarse igual. Y `for update` para que nadie lo toque
    -- entre que se comprueba y se borra.
    select e.id into el_gasto
      from public.expenses e
     where e.group_id = g_bierzo
       and left(md5(e.id::text), 8) = RESORTE
       for update;

    if el_gasto is null then
        raise exception 'No se encuentra el gasto con resorte %: no se toca nada', RESORTE;
    end if;

    -- ── 2 · Exigir que sea EXACTAMENTE el esperado ───────────
    select count(*) into n
      from public.expenses e
     where e.id = el_gasto
       and e.group_id      = g_bierzo
       and e.description   = CONCEPTO
       and round(e.amount * 100) = C_GASTO
       and e.payer_share   = 0.500
       and e.paid_by       = buganvilla
       and e.spent_on      = date '2026-08-17'
       and e.client_id is not null;

    if n <> 1 then
        raise exception
            'El gasto no coincide con lo diagnosticado: no se borra nada. '
            'Vuelve a ejecutar el diagnóstico 103.';
    end if;

    -- «No vinculado a ningún traslado» es estructural: `transfer_id` vive en
    -- `settlements`, no en `expenses`, así que un gasto no puede tenerlo. Lo
    -- que sí se comprueba es que no exista ningún traslado todavía (paso 3).

    -- Y que no haya otro con el mismo concepto.
    select count(*) into n from public.expenses e
     where e.group_id = g_bierzo and e.description = CONCEPTO;
    if n <> 1 then
        raise exception 'Hay % gastos con ese concepto en Bierzo, se esperaba 1', n;
    end if;
    raise notice '[1] ok — el gasto es exactamente el diagnosticado (% céntimos)', C_GASTO;

    -- ── 3 · Volver a comprobar los saldos de partida ─────────
    s_o := public.saldo_centimos(g_slovenia, laurel, buganvilla);
    s_d := public.saldo_centimos(g_bierzo,   laurel, buganvilla);
    if s_o <> C_SLOVENIA then
        raise exception 'Slovenia está en % y se esperaba %', s_o, C_SLOVENIA;
    end if;
    if s_d <> C_BIERZO_ANTES then
        raise exception 'Bierzo está en % y se esperaba %', s_d, C_BIERZO_ANTES;
    end if;

    select count(*) into n from public.balance_transfers;
    if n <> 0 then
        raise exception 'Ya hay % traslado(s): esta corrección asume que no hay ninguno', n;
    end if;

    select round(sum(e.amount) * 100) into total
      from public.expenses e where e.group_id = g_bierzo;
    if total <> C_TOTAL_ANTES then
        raise exception 'El total gastado de Bierzo es % y se esperaba %', total, C_TOTAL_ANTES;
    end if;
    raise notice '[2] ok — Slovenia %, Bierzo %, 0 traslados, total gastado %',
                 s_o, s_d, total;

    -- ── 4 · Borrar SOLO ese gasto ────────────────────────────
    delete from public.expenses where id = el_gasto;
    get diagnostics n = row_count;
    if n <> 1 then
        raise exception 'El borrado ha afectado a % filas, se esperaba 1', n;
    end if;
    raise notice '[3] ok — apunte manual borrado';

    -- ── 5 · Comprobar el efecto de borrarlo ──────────────────
    s_d := public.saldo_centimos(g_bierzo, laurel, buganvilla);
    if s_d <> C_BIERZO_MEDIO then
        raise exception 'Tras borrar, Bierzo está en % y se esperaba %', s_d, C_BIERZO_MEDIO;
    end if;

    select round(sum(e.amount) * 100), count(*) into total, n
      from public.expenses e where e.group_id = g_bierzo;
    if total <> C_TOTAL_FIN then
        raise exception 'El total gastado de Bierzo es % y se esperaba %', total, C_TOTAL_FIN;
    end if;
    if n <> 2 then
        raise exception 'Quedan % gastos en Bierzo y se esperaban 2', n;
    end if;
    raise notice '[4] ok — Bierzo pasa a %, total gastado % con % gastos', s_d, total, n;

    -- ── 6 · El traslado real ─────────────────────────────────
    -- Importe NULL: lo calcula el servidor. Clave fija: si esto se
    -- reintentara, no trasladaría dos veces.
    if exists (select 1 from public.balance_transfers where idempotency_key = CLAVE) then
        raise exception 'Esa clave de idempotencia ya se usó: revisa antes de repetir';
    end if;

    t := public.trasladar_saldo(g_slovenia, g_bierzo, CLAVE, null);
    raise notice '[5] ok — traslado ejecutado por % céntimos', round(t.importe * 100);

    -- ── 7 · Exigir el resultado, condición por condición ─────
    s_o := public.saldo_centimos(g_slovenia, laurel, buganvilla);
    s_d := public.saldo_centimos(g_bierzo,   laurel, buganvilla);

    if s_o <> 0 then
        raise exception 'Slovenia ha quedado en % y debía quedar a cero', s_o;
    end if;
    if s_d <> C_BIERZO_FIN then
        raise exception 'Bierzo ha quedado en % y se esperaba %', s_d, C_BIERZO_FIN;
    end if;
    if round(t.importe * 100) <> abs(C_SLOVENIA) then
        raise exception 'Se han trasladado % céntimos y se esperaban %',
                        round(t.importe * 100), abs(C_SLOVENIA);
    end if;
    if t.deudor <> laurel or t.acreedor <> buganvilla then
        raise exception 'La dirección de la deuda no es la esperada';
    end if;

    select count(*) into n from public.balance_transfers;
    if n <> 1 then raise exception 'Hay % traslados y se esperaba 1', n; end if;

    select count(*) into n from public.settlements
     where transfer_id = t.id and transfer_role in ('origen','destino');
    if n <> 2 then raise exception 'Hay % liquidaciones del traslado y se esperaban 2', n; end if;

    if exists (select 1 from public.expenses where id = el_gasto) then
        raise exception 'El gasto manual sigue ahí';
    end if;

    select round(sum(e.amount) * 100), count(*) into total, n
      from public.expenses e where e.group_id = g_bierzo;
    if total <> C_TOTAL_FIN then
        raise exception 'El total gastado de Bierzo ha cambiado: %', total;
    end if;
    if n <> 2 then raise exception 'Bierzo tiene % gastos y se esperaban 2', n; end if;

    -- La suma que debe conservarse es la de DESPUÉS de borrar el apunte
    -- falso, no la de antes: aquella contenía la deuda duplicada.
    if (s_o + s_d) <> (C_SLOVENIA + C_BIERZO_MEDIO) then
        raise exception 'La deuda global ha cambiado: % ≠ %',
                        s_o + s_d, C_SLOVENIA + C_BIERZO_MEDIO;
    end if;
    raise notice '[6] ok — Slovenia %, Bierzo %, suma % conservada', s_o, s_d, s_o + s_d;

    -- ── 8 · Nada más se ha movido ────────────────────────────
    if (select count(*) from public.profiles) <> 2
       or (select count(*) from public.groups) <> 3
       or (select count(*) from public.group_members) <> 6 then
        raise exception 'Perfiles, grupos o membresías han cambiado';
    end if;

    if (select count(*) from public.expenses e where not exists
          (select 1 from public.group_members m
            where m.group_id = e.group_id and m.user_id = e.paid_by)) <> 0 then
        raise exception 'Hay pagadores fuera de su grupo';
    end if;

    if (select count(*) from pg_policies where schemaname='public'
         and tablename in ('profiles','groups','group_members','expenses','settlements')) <> 19
       or (select count(*) from pg_policies where schemaname='public'
            and tablename in ('viajes','viaje_diario','viaje_fotos')) <> 12
       or (select count(*) from pg_policies where schemaname='public'
            and tablename in ('profiles','groups','group_members','expenses','settlements',
                              'viajes','viaje_diario','viaje_fotos')
            and (qual='true' or with_check='true')) <> 0 then
        raise exception 'Las políticas de Splitwise o de Viajes han cambiado';
    end if;

    if ((select count(*) from public.viajes), (select count(*) from public.viaje_diario),
        (select count(*) from public.viaje_fotos)) <> (3::bigint, 2::bigint, 8::bigint) then
        raise exception 'La aplicación de viajes ha cambiado';
    end if;

    raise notice '[7] ok — invariantes, RLS, Splitwise y Viajes intactos';
    raise notice 'CORRECCIÓN CORRECTA — lista para confirmar';
end
$corregir$;

select 'Corrección del apunte manual completada' as resultado;
