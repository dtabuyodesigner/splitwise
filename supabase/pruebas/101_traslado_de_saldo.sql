-- ============================================================
-- Traslado de saldo · DML real
--
-- Se ejecuta DESPUÉS de 0007, sobre el escenario histórico. Cada bloque
-- suplanta a una cuenta con `set local role authenticated` + el `sub` del
-- JWT, como el resto del banco.
--
-- Lo que se persigue: que el dinero no se cree ni se pierda, que no se pueda
-- trasladar dos veces, y que nadie ajeno pueda tocarlo.
-- ============================================================
\set ON_ERROR_STOP on

begin;

-- Las aserciones se cuentan de verdad, no se escribe el número a mano.
create temporary table aserciones (etiqueta text primary key) on commit drop;
grant insert, select on aserciones to authenticated;

-- Exige que el error sea el que se busca, no cualquiera de su clase.
-- `invalid_parameter_value` lo usan OCHO rechazos distintos de la función:
-- capturarlo a secas haría pasar «más de lo que se debe» cuando en realidad
-- el escenario falló por otra cosa.
create or replace function pg_temp.ok(p_etiqueta text, p_texto text)
returns void language plpgsql as $$
begin
    insert into aserciones values (p_etiqueta);
    raise notice '[%] ok — %', p_etiqueta, p_texto;
end $$;
grant execute on function pg_temp.ok(text, text) to authenticated;

-- Un tercero registrado, sin relación con los grupos.
insert into auth.users (id, email, raw_user_meta_data)
values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
        'atacante@ejemplo.invalido',
        '{"display_name":"Atacante","color":"laurel"}'::jsonb)
on conflict (id) do nothing;

-- Estado de partida, para poder comparar al final.
create temporary table antes on commit drop as
select (select count(*) from public.expenses)                      as gastos,
       (select coalesce(sum(amount),0) from public.expenses)        as total_gastado,
       (select count(*) from public.settlements)                    as liquidaciones,
       (select count(*) from public.groups)                         as grupos;
grant select on antes to authenticated;

create temporary table ids on commit drop as
select (select id from public.groups where name = 'Slovenia')          as slovenia,
       (select id from public.groups where name = 'Bierzo & Asturias') as bierzo,
       (select id from public.groups where name = 'Casa')              as casa,
       (select id from public.profiles order by created_at, id limit 1)          as a,
       (select id from public.profiles order by created_at, id offset 1 limit 1) as b;
grant select on ids to authenticated;

do $$
declare
  i record; s bigint;
begin
  select * into i from ids;
  s := public.saldo_centimos(i.slovenia, i.a, i.b);
  if s = 0 then raise exception '[Preparación] Slovenia está saldado: la prueba no valdría'; end if;
  raise notice '[T00] partida — Slovenia %, Bierzo %, Casa % (céntimos, signo respecto a la primera persona)',
               s, public.saldo_centimos(i.bierzo, i.a, i.b), public.saldo_centimos(i.casa, i.a, i.b);
end $$;

-- ══ Como la persona A ════════════════════════════════════════
do $$
declare i record;
begin
  select * into i from ids;
  perform set_config('request.jwt.claims', json_build_object('sub', i.a)::text, true);
end $$;
set local role authenticated;

do $$
declare
  i record;
  t public.balance_transfers;
  s_o bigint; s_d bigint; s_o2 bigint; s_d2 bigint;
  n integer;
begin
  select * into i from ids;

  -- ── 1 · Rechazos ───────────────────────────────────────────
  begin
    perform public.trasladar_saldo(i.slovenia, i.slovenia, 'k-mismo');
    raise exception '[T01] FALLA — ha aceptado destino igual al origen';
  exception when invalid_parameter_value then
    if sqlerrm not like '%mismo que el de origen%' then
      raise exception '[T01] FALLA — rechazado por otro motivo: %', sqlerrm;
    end if;
    perform pg_temp.ok('T01', 'destino igual al origen: rechazado');
  end;

  begin
    perform public.trasladar_saldo(i.slovenia, i.bierzo, 'k-cero', 0);
    raise exception '[T02] FALLA — ha aceptado importe cero';
  exception when invalid_parameter_value then
    if sqlerrm not like '%mayor que cero%' then
      raise exception '[T02] FALLA — rechazado por otro motivo: %', sqlerrm;
    end if;
    perform pg_temp.ok('T02', 'importe cero: rechazado');
  end;

  begin
    perform public.trasladar_saldo(i.slovenia, i.bierzo, 'k-neg', -10);
    raise exception '[T03] FALLA — ha aceptado importe negativo';
  exception when invalid_parameter_value then
    if sqlerrm not like '%mayor que cero%' then
      raise exception '[T03] FALLA — rechazado por otro motivo: %', sqlerrm;
    end if;
    perform pg_temp.ok('T03', 'importe negativo: rechazado');
  end;

  -- El límite JUSTO, no un número enorme: un off-by-one o un céntimo de
  -- redondeo no lo detectaría 999999.
  s_o := public.saldo_centimos(i.slovenia, i.a, i.b);
  begin
    perform public.trasladar_saldo(i.slovenia, i.bierzo, 'k-exceso',
                                   round((abs(s_o) + 1)::numeric / 100, 2));
    raise exception '[T04] FALLA — ha aceptado un céntimo más que la deuda';
  exception when invalid_parameter_value then
    if sqlerrm not like '%la deuda del grupo es de%' then
      raise exception '[T04] FALLA — rechazado por otro motivo: %', sqlerrm;
    end if;
    perform pg_temp.ok('T04', 'un céntimo más que la deuda: rechazado');
  end;

  begin
    perform public.trasladar_saldo(i.casa, i.bierzo, 'k-saldado');
    raise exception '[T05] FALLA — ha aceptado un grupo saldado';
  exception when invalid_parameter_value then
    if sqlerrm not like '%está saldado%' then
      raise exception '[T05] FALLA — rechazado por otro motivo: %', sqlerrm;
    end if;
    perform pg_temp.ok('T05', 'grupo sin deuda: rechazado');
  end;

  -- ── 2 · Traslado PARCIAL ───────────────────────────────────
  s_o := public.saldo_centimos(i.slovenia, i.a, i.b);
  s_d := public.saldo_centimos(i.bierzo,   i.a, i.b);

  t := public.trasladar_saldo(i.slovenia, i.bierzo, 'k-parcial', 20.00);

  s_o2 := public.saldo_centimos(i.slovenia, i.a, i.b);
  s_d2 := public.saldo_centimos(i.bierzo,   i.a, i.b);

  if abs(s_o2 - s_o) <> 2000 then
    raise exception '[T06] FALLA — el origen se ha movido % céntimos, se esperaban 2000', abs(s_o2 - s_o);
  end if;
  if abs(s_d2 - s_d) <> 2000 then
    raise exception '[T07] FALLA — el destino se ha movido % céntimos, se esperaban 2000', abs(s_d2 - s_d);
  end if;
  -- La suma de las dos deudas se conserva: no se crea ni se destruye dinero.
  if (s_o2 + s_d2) <> (s_o + s_d) then
    raise exception '[T08] FALLA — la deuda global ha cambiado: % → %', s_o + s_d, s_o2 + s_d2;
  end if;
  perform pg_temp.ok('T06', 'traslado parcial: el origen baja 20,00 €');
  perform pg_temp.ok('T07', 'traslado parcial: el destino sube 20,00 €');
  perform pg_temp.ok('T08', 'la suma global de deuda se conserva');

  -- Dirección: el origen se acerca a cero, el destino se aleja.
  if abs(s_o2) >= abs(s_o) then
    raise exception '[T09] FALLA — el origen no se ha acercado a cero: % → %', s_o, s_o2;
  end if;
  perform pg_temp.ok('T09', 'la dirección es la correcta: el origen se salda, el destino asume');

  -- ── 3 · Idempotencia ───────────────────────────────────────
  if (public.trasladar_saldo(i.slovenia, i.bierzo, 'k-parcial', 20.00)).id <> t.id then
    raise exception '[T10] FALLA — la misma clave ha creado otro traslado';
  end if;
  select count(*) into n from public.balance_transfers where idempotency_key = 'k-parcial';
  if n <> 1 then raise exception '[T10] FALLA — hay % traslados con la misma clave', n; end if;
  if public.saldo_centimos(i.slovenia, i.a, i.b) <> s_o2 then
    raise exception '[T11] FALLA — el reintento ha movido el saldo otra vez';
  end if;
  perform pg_temp.ok('T10', 'reintento con la misma clave: no duplica');
  perform pg_temp.ok('T11', 'reintento con la misma clave: no mueve el saldo');

  -- ── 4 · Traslado TOTAL de lo que queda ─────────────────────
  t := public.trasladar_saldo(i.slovenia, i.bierzo, 'k-total');
  if public.saldo_centimos(i.slovenia, i.a, i.b) <> 0 then
    raise exception '[T12] FALLA — el origen no ha quedado saldado: %',
                    public.saldo_centimos(i.slovenia, i.a, i.b);
  end if;
  perform pg_temp.ok('T12', 'traslado total: el origen queda a cero');

  if (s_o + s_d) <> (public.saldo_centimos(i.slovenia, i.a, i.b)
                     + public.saldo_centimos(i.bierzo, i.a, i.b)) then
    raise exception '[T13] FALLA — la deuda global ha cambiado tras el traslado total';
  end if;
  perform pg_temp.ok('T13', 'tras el traslado total, la deuda global sigue conservándose');

  -- ── 5 · Nada de esto es un gasto ───────────────────────────
  if (select count(*) from public.expenses) <> (select gastos from antes) then
    raise exception '[T14] FALLA — se han creado gastos';
  end if;
  if (select coalesce(sum(amount),0) from public.expenses) <> (select total_gastado from antes) then
    raise exception '[T14] FALLA — el total gastado ha cambiado';
  end if;
  perform pg_temp.ok('T14', 'ni un gasto nuevo: el total gastado y las categorías no se tocan');

  -- ── 6 · Deshacer ───────────────────────────────────────────
  -- Se compara con el valor EXACTO de antes del traslado, no solo con que
  -- «se haya movido»: una reversión por la mitad, o con los grupos
  -- intercambiados, conservaría la suma global y pasaría igual.
  s_o2 := public.saldo_centimos(i.slovenia, i.a, i.b);
  s_d2 := public.saldo_centimos(i.bierzo,   i.a, i.b);
  perform public.revertir_traslado(t.id);
  if public.saldo_centimos(i.slovenia, i.a, i.b)
     <> s_o2 - (round(t.importe * 100))::bigint * sign(s_o2)::bigint * 0 - 0 then
    null;  -- se comprueba abajo con el valor absoluto del importe
  end if;
  if abs(public.saldo_centimos(i.slovenia, i.a, i.b) - s_o2) <> round(t.importe * 100) then
    raise exception '[T15] FALLA — deshacer ha movido el origen % céntimos y el traslado era de %',
                    abs(public.saldo_centimos(i.slovenia, i.a, i.b) - s_o2), round(t.importe * 100);
  end if;
  if abs(public.saldo_centimos(i.bierzo, i.a, i.b) - s_d2) <> round(t.importe * 100) then
    raise exception '[T15] FALLA — deshacer ha movido el destino un importe distinto';
  end if;
  if (public.saldo_centimos(i.slovenia, i.a, i.b)
      + public.saldo_centimos(i.bierzo, i.a, i.b)) <> (s_o2 + s_d2) then
    raise exception '[T15] FALLA — deshacer ha cambiado la deuda global';
  end if;
  if (select revertido_en from public.balance_transfers where id = t.id) is null then
    raise exception '[T15] FALLA — no ha quedado marcado como revertido';
  end if;
  perform pg_temp.ok('T15', 'deshacer devuelve exactamente el importe a los dos grupos');

  -- Deshacer dos veces no hace nada nuevo.
  s_o2 := public.saldo_centimos(i.slovenia, i.a, i.b);
  perform public.revertir_traslado(t.id);
  if public.saldo_centimos(i.slovenia, i.a, i.b) <> s_o2 then
    raise exception '[T16] FALLA — deshacer dos veces ha vuelto a mover el saldo';
  end if;
  perform pg_temp.ok('T16', 'deshacer dos veces es idempotente');

  -- ── 7 · Las mitades no se tocan a mano ─────────────────────
  begin
    delete from public.settlements where transfer_id = t.id and transfer_role = 'origen';
    raise exception '[T17] FALLA — se ha podido borrar media transferencia';
  exception when insufficient_privilege then
    perform pg_temp.ok('T17', 'no se puede borrar una mitad del traslado');
  end;
  begin
    update public.settlements set amount = 1 where transfer_id = t.id;
    raise exception '[T18] FALLA — se ha podido editar una mitad';
  exception when insufficient_privilege then
    perform pg_temp.ok('T18', 'no se puede editar una mitad del traslado');
  end;

  -- ── 8 · Lo que la revisión encontró: enganches a mano ───────
  -- Inyectar una TERCERA mitad dejaba el traslado imposible de deshacer.
  begin
    insert into public.settlements
      (group_id, from_user, to_user, amount, note, settled_on, client_id,
       transfer_id, transfer_role)
    values (i.slovenia, i.a, i.b, 0.01, 'inyectada', current_date,
            'inyectada-1', t.id, 'origen');
    raise exception '[T23] FALLA — se ha podido inyectar una tercera mitad';
  exception when insufficient_privilege then
    perform pg_temp.ok('T23', 'no se puede inyectar una mitad extra en un traslado');
  end;

  -- Marcar una liquidación normal con transfer_id la volvía indestructible.
  begin
    update public.settlements
       set transfer_id = t.id, transfer_role = 'origen'
     where transfer_id is null and group_id = i.slovenia;
    raise exception '[T24] FALLA — se ha podido enganchar una liquidación normal';
  exception when insufficient_privilege then
    perform pg_temp.ok('T24', 'no se puede enganchar una liquidación normal a un traslado');
  end;

  -- El traslado es un registro, no un formulario.
  begin
    update public.balance_transfers set importe = 99999 where id = t.id;
    raise exception '[T25] FALLA — se ha podido cambiar el importe de un traslado';
  exception when insufficient_privilege then
    perform pg_temp.ok('T25', 'no se puede cambiar el importe de un traslado');
  end;
  begin
    update public.balance_transfers set revertido_en = null where id = t.id;
    raise exception '[T26] FALLA — se ha podido des-revertir un traslado';
  exception when insufficient_privilege then
    perform pg_temp.ok('T26', 'no se puede des-revertir un traslado');
  end;
end $$;
reset role;

-- ══ El atacante ══════════════════════════════════════════════
select set_config('request.jwt.claims',
                  '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}', true);
set local role authenticated;

do $$
declare i record; n integer;
begin
  select * into i from ids;

  begin
    perform public.trasladar_saldo(i.slovenia, i.bierzo, 'k-atacante');
    raise exception '[T19] FALLA — un tercero ha trasladado saldo ajeno';
  exception when insufficient_privilege then
    perform pg_temp.ok('T19', 'ATAQUE: un tercero no puede trasladar saldo ajeno');
  end;

  select count(*) into n from public.balance_transfers;
  if n <> 0 then
    raise exception '[T20] FALLA — el tercero ve % traslados ajenos', n;
  end if;
  perform pg_temp.ok('T20', 'ATAQUE: el tercero no ve ningún traslado ajeno');

  -- Fabricar un traslado a mano, sin la función.
  begin
    insert into public.balance_transfers
      (grupo_origen, grupo_destino, deudor, acreedor, importe, creado_por, idempotency_key)
    values (i.slovenia, i.bierzo, i.a, i.b, 1000,
            'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'k-fabricado');
    raise exception '[T21] FALLA — el tercero ha fabricado un traslado a mano';
  exception when insufficient_privilege or check_violation then
    perform pg_temp.ok('T21', 'ATAQUE: el tercero no puede fabricar un traslado a mano');
  end;
end $$;
reset role;

-- ══ Media transferencia no puede existir ═════════════════════
do $$
declare i record;
begin
  select * into i from ids;
  begin
    -- Una fila de traslado SIN sus dos liquidaciones: el trigger diferido
    -- tiene que abortarla al confirmar el savepoint.
    begin
      insert into public.balance_transfers
        (grupo_origen, grupo_destino, deudor, acreedor, importe, creado_por, idempotency_key)
      values (i.slovenia, i.bierzo, i.a, i.b, 50, i.a, 'k-huerfano');
      -- Forzar la comprobación diferida.
      set constraints all immediate;
      raise exception '[T22] FALLA — ha existido media transferencia';
    exception when integrity_constraint_violation then
      if sqlerrm not like '%Traslado incoherente%' then
        raise exception '[T22] FALLA — abortó por otro motivo: %', sqlerrm;
      end if;
      perform pg_temp.ok('T22', 'media transferencia no puede existir: el trigger diferido la aborta');
    end;
  end;
end $$;

-- ══ Un grupo con traslados se sigue pudiendo borrar ══════════
-- El `on delete restrict` del vínculo y el trigger de protección hacían
-- imposible borrar para siempre cualquier grupo que hubiera participado en
-- un traslado, aunque la política `groups_borrar` dijera que sí.
do $$
declare i record; g uuid;
begin
  select * into i from ids;
  -- La sesión se fija ANTES: crear un grupo dispara `tras_crear_grupo` de
  -- 0002, que mete a su creador como propietario.
  perform set_config('request.jwt.claims', json_build_object('sub', i.a)::text, true);
  insert into public.groups (id, name, created_by) values (gen_random_uuid(), 'Temporal para borrar', i.a)
  returning id into g;
  insert into public.group_members (group_id, user_id, role) values (g, i.b, 'member')
  on conflict do nothing;
  if array_length(public.pareja_del_grupo(g), 1) is distinct from 2 then
    raise exception '[T27] el grupo temporal tiene % miembros', (select count(*) from public.group_members where group_id = g);
  end if;
  insert into public.expenses (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
  values (g, i.a, 40, 'x', 'otros', 0, current_date, 'tmp-1');
  perform public.trasladar_saldo(g, i.bierzo, 'k-borrar');
  delete from public.groups where id = g;
  if exists (select 1 from public.groups where id = g) then
    raise exception '[T27] FALLA — el grupo no se ha borrado';
  end if;
  perform pg_temp.ok('T27', 'un grupo que participó en un traslado se sigue pudiendo borrar');
end $$;

-- ══ Recuento real de aserciones ══════════════════════════════
do $$
declare n integer;
begin
  select count(*) into n from aserciones;
  if n <> 27 then
    raise exception 'Se esperaban 27 aserciones y se han ejecutado %: alguna no ha llegado a correr', n;
  end if;
  raise notice 'Traslado de saldo: % aserciones superadas', n;
end $$;

rollback;

select 'Traslado de saldo: aserciones comprobadas' as resultado;
