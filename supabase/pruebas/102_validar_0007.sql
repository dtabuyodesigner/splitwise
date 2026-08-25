-- ============================================================
-- Validación de 0007 sobre PRODUCCIÓN
--
-- Comprueba que el traslado de saldo ha quedado instalado y CERRADO. Los
-- ataques van dentro de una transacción que se deshace: no dejan rastro.
--
-- NO ejecuta ningún traslado real y NO toca ningún gasto.
--
-- Sin un solo recuento mutable de gastos: la aplicación se usa a diario y un
-- número congelado convertiría el uso normal en una alarma.
-- ============================================================
\set ON_ERROR_STOP on

begin;

create temporary table comprobado (etiqueta text primary key) on commit drop;
create or replace function pg_temp.ok(p_et text, p_txt text)
returns void language plpgsql as $$
begin
    insert into comprobado values (p_et);
    raise notice '[%] ok — %', p_et, p_txt;
end $$;

-- ── Estructura ───────────────────────────────────────────────
do $$
declare n integer; ok_def boolean;
begin
    if to_regclass('public.balance_transfers') is null then
        raise exception '[E1] FALLA — no existe balance_transfers';
    end if;
    perform pg_temp.ok('E1', 'la tabla balance_transfers existe');

    select count(*) into n from information_schema.columns
     where table_schema='public' and table_name='settlements'
       and column_name in ('transfer_id','transfer_role');
    if n <> 2 then raise exception '[E2] FALLA — settlements tiene % de las 2 columnas nuevas', n; end if;
    perform pg_temp.ok('E2', 'settlements tiene transfer_id y transfer_role');

    select count(*) into n from pg_constraint
     where conrelid='public.settlements'::regclass
       and conname in ('ck_settlement_transfer_role','ck_settlement_transfer_par');
    if n <> 2 then raise exception '[E3] FALLA — faltan restricciones nuevas (% de 2)', n; end if;
    select count(*) into n from pg_constraint
     where conrelid='public.balance_transfers'::regclass and contype='c';
    if n < 3 then raise exception '[E4] FALLA — balance_transfers tiene % checks, se esperaban 3', n; end if;
    perform pg_temp.ok('E3', 'las restricciones de coherencia están puestas');

    if not exists (select 1 from pg_indexes where schemaname='public'
                    and indexname='uq_transfer_idempotency') then
        raise exception '[E5] FALLA — falta el índice único de idempotencia';
    end if;
    perform pg_temp.ok('E4', 'la clave de idempotencia tiene índice único');

    -- RLS y políticas
    if not exists (select 1 from pg_tables where schemaname='public'
                    and tablename='balance_transfers' and rowsecurity) then
        raise exception '[E6] FALLA — balance_transfers sin RLS';
    end if;
    select count(*) into n from pg_policies
     where schemaname='public' and tablename='balance_transfers';
    if n <> 3 then raise exception '[E7] FALLA — % políticas en balance_transfers, se esperaban 3', n; end if;
    if exists (select 1 from pg_policies where schemaname='public'
                and tablename='balance_transfers' and cmd='DELETE') then
        raise exception '[E8] FALLA — hay política de DELETE: los traslados no se borran';
    end if;
    if exists (select 1 from pg_policies where schemaname='public'
                and tablename='balance_transfers' and (qual='true' or with_check='true')) then
        raise exception '[E9] FALLA — alguna política de traslados usa `true`';
    end if;
    perform pg_temp.ok('E5', 'RLS activa, 3 políticas, ninguna abierta y sin DELETE');

    -- Las dos funciones, y sus privilegios
    if to_regprocedure('public.trasladar_saldo(uuid,uuid,text,numeric)') is null then
        raise exception '[E10] FALLA — no existe trasladar_saldo';
    end if;
    if to_regprocedure('public.revertir_traslado(uuid)') is null then
        raise exception '[E11] FALLA — no existe revertir_traslado';
    end if;
    perform pg_temp.ok('E6', 'trasladar_saldo y revertir_traslado existen');

    if has_function_privilege('public', 'public.trasladar_saldo(uuid,uuid,text,numeric)', 'execute')
       or has_function_privilege('anon', 'public.trasladar_saldo(uuid,uuid,text,numeric)', 'execute') then
        raise exception '[E12] FALLA — trasladar_saldo es ejecutable por PUBLIC o anon';
    end if;
    if not has_function_privilege('authenticated', 'public.trasladar_saldo(uuid,uuid,text,numeric)', 'execute') then
        raise exception '[E13] FALLA — authenticated NO puede ejecutar trasladar_saldo';
    end if;
    perform pg_temp.ok('E7', 'las RPC son de authenticated, no de PUBLIC ni anon');

    -- No deben ser SECURITY DEFINER: la RLS tiene que seguir evaluándose.
    select prosecdef into ok_def from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
     where ns.nspname='public' and p.proname='trasladar_saldo';
    if coalesce(ok_def, true) then
        raise exception '[E14] FALLA — trasladar_saldo es SECURITY DEFINER: saltaría la RLS';
    end if;
    perform pg_temp.ok('E8', 'trasladar_saldo es security invoker: la RLS sigue mandando');

    -- Los dos triggers de protección
    if not exists (select 1 from pg_trigger where tgname='tr_traslado_coherente'
                    and tgrelid='public.balance_transfers'::regclass) then
        raise exception '[E15] FALLA — falta el trigger de coherencia';
    end if;
    if not exists (select 1 from pg_trigger where tgname='tr_proteger_traslado'
                    and tgrelid='public.balance_transfers'::regclass) then
        raise exception '[E16] FALLA — falta el trigger de inmutabilidad';
    end if;
    if not exists (select 1 from pg_trigger where tgname='tr_proteger_liquidacion_traslado'
                    and tgrelid='public.settlements'::regclass) then
        raise exception '[E17] FALLA — falta el trigger que protege las liquidaciones';
    end if;
    perform pg_temp.ok('E9', 'los tres triggers de protección están puestos');
end $$;

-- ── Que nadie pueda fabricar nada a mano ─────────────────────
-- Se hace con un traslado de mentira entre dos grupos reales, y se deshace.
do $$
declare
    g1 uuid; g2 uuid; p1 uuid; p2 uuid; t uuid;
begin
    select id into g1 from public.groups order by created_at limit 1;
    select id into g2 from public.groups order by created_at offset 1 limit 1;
    select user_id into p1 from public.group_members where group_id = g1 order by user_id limit 1;
    select user_id into p2 from public.group_members where group_id = g1 order by user_id offset 1 limit 1;
    if g2 is null or p2 is null then
        raise notice '[A0] omitido — no hay dos grupos con pareja para probar los ataques';
        return;
    end if;

    -- Una fila de traslado sin sus dos mitades no puede sobrevivir.
    begin
        insert into public.balance_transfers
          (grupo_origen, grupo_destino, deudor, acreedor, importe, creado_por, idempotency_key)
        values (g1, g2, p1, p2, 1, p1, 'validacion-huerfano');
        set constraints all immediate;
        raise exception '[A1] FALLA — ha existido media transferencia';
    exception when integrity_constraint_violation then
        if sqlerrm not like '%Traslado incoherente%' then
            raise exception '[A1] FALLA — abortó por otro motivo: %', sqlerrm;
        end if;
        perform pg_temp.ok('A1', 'media transferencia no puede existir');
    end;

    -- Enganchar una liquidación a un traslado a mano.
    begin
        insert into public.settlements
          (group_id, from_user, to_user, amount, settled_on, transfer_id, transfer_role)
        values (g1, p1, p2, 1, current_date, gen_random_uuid(), 'origen');
        raise exception '[A2] FALLA — se ha podido enganchar una liquidación a mano';
    exception
        when insufficient_privilege then
            perform pg_temp.ok('A2', 'no se puede enganchar una liquidación a un traslado a mano');
        when foreign_key_violation then
            perform pg_temp.ok('A2', 'no se puede enganchar una liquidación a un traslado a mano');
    end;
end $$;

-- ── Rechazos de la función ───────────────────────────────────
-- `trasladar_saldo` exige sesión: sin JWT, `auth.uid()` es nulo y todo se
-- rechaza por «No hay sesión», que no demuestra nada de lo que se quiere
-- comprobar. Se suplanta a la primera persona, como hace el resto del banco.
do $$
declare quien uuid;
begin
    select id into quien from public.profiles order by created_at, id limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', quien)::text, true);
end $$;

do $$
declare g1 uuid; g2 uuid; con_deuda uuid;
begin
    select id into g1 from public.groups order by created_at limit 1;
    select id into g2 from public.groups order by created_at offset 1 limit 1;

    begin
        perform public.trasladar_saldo(g1, g1, 'validacion-mismo');
        raise exception '[A3] FALLA — ha aceptado destino igual al origen';
    exception when invalid_parameter_value then
        if sqlerrm not like '%mismo que el de origen%' then
            raise exception '[A3] FALLA — rechazado por otro motivo: %', sqlerrm;
        end if;
        perform pg_temp.ok('A3', 'destino igual al origen: rechazado');
    end;

    -- Un grupo inventado: no se pertenece a él.
    begin
        perform public.trasladar_saldo('00000000-0000-0000-0000-000000000000'::uuid, g2,
                                       'validacion-ajeno');
        raise exception '[A5] FALLA — ha aceptado un grupo al que no se pertenece';
    exception
        when insufficient_privilege then
            perform pg_temp.ok('A5', 'grupo ajeno: rechazado');
        when invalid_parameter_value then
            perform pg_temp.ok('A5', 'grupo ajeno: rechazado');
    end;

    -- El importe solo se valida DESPUÉS de comprobar que hay deuda, así que
    -- estas dos necesitan un grupo que la tenga. Con uno saldado, la función
    -- rechaza por «saldado» y la aserción no probaría lo que dice.
    select g.id into con_deuda from public.groups g
     where public.pareja_del_grupo(g.id) is not null
       and public.saldo_centimos(g.id, (public.pareja_del_grupo(g.id))[1],
                                       (public.pareja_del_grupo(g.id))[2]) <> 0
     order by g.created_at limit 1;

    if con_deuda is null then
        raise notice '[A4] omitido — ningún grupo con deuda con la que probar el importe';
        return;
    end if;
    select g.id into g2 from public.groups g
     where g.id <> con_deuda
       and public.pareja_del_grupo(g.id) = public.pareja_del_grupo(con_deuda)
     order by g.created_at limit 1;
    if g2 is null then
        raise notice '[A4] omitido — no hay otro grupo con la misma pareja';
        return;
    end if;

    begin
        perform public.trasladar_saldo(con_deuda, g2, 'validacion-cero', 0);
        raise exception '[A4] FALLA — ha aceptado importe cero';
    exception when invalid_parameter_value then
        if sqlerrm not like '%mayor que cero%' then
            raise exception '[A4] FALLA — rechazado por otro motivo: %', sqlerrm;
        end if;
        perform pg_temp.ok('A4', 'importe cero: rechazado');
    end;

    begin
        perform public.trasladar_saldo(con_deuda, g2, 'validacion-exceso', 9999999);
        raise exception '[A6] FALLA — ha aceptado más que la deuda';
    exception when invalid_parameter_value then
        if sqlerrm not like '%la deuda del grupo es de%' then
            raise exception '[A6] FALLA — rechazado por otro motivo: %', sqlerrm;
        end if;
        perform pg_temp.ok('A6', 'más de lo que se debe: rechazado');
    end;
end $$;

-- Sigue con la misma sesión suplantada.
-- ── Idempotencia, sin dejar nada ─────────────────────────────
do $$
declare
    g1 uuid; g2 uuid; t1 public.balance_transfers; t2 public.balance_transfers;
    n integer;
begin
    select g.id into g1 from public.groups g
     where public.pareja_del_grupo(g.id) is not null
       and public.saldo_centimos(g.id, (public.pareja_del_grupo(g.id))[1],
                                       (public.pareja_del_grupo(g.id))[2]) <> 0
     order by g.created_at limit 1;
    if g1 is null then
        raise notice '[I0] omitido — ningún grupo con deuda para probar la idempotencia';
        return;
    end if;
    select g.id into g2 from public.groups g
     where g.id <> g1 and public.pareja_del_grupo(g.id) = public.pareja_del_grupo(g1)
     order by g.created_at limit 1;
    if g2 is null then
        raise notice '[I0] omitido — no hay otro grupo con la misma pareja';
        return;
    end if;

    t1 := public.trasladar_saldo(g1, g2, 'validacion-idem', 0.01);
    t2 := public.trasladar_saldo(g1, g2, 'validacion-idem', 0.01);
    if t1.id <> t2.id then
        raise exception '[I1] FALLA — la misma clave ha creado dos traslados';
    end if;
    select count(*) into n from public.balance_transfers where idempotency_key='validacion-idem';
    if n <> 1 then raise exception '[I1] FALLA — hay % traslados con la misma clave', n; end if;
    perform pg_temp.ok('I1', 'la misma clave devuelve el mismo traslado y no duplica');

    -- Y no se puede cambiar a mano.
    begin
        update public.balance_transfers set importe = 999 where id = t1.id;
        raise exception '[I2] FALLA — se ha podido cambiar el importe';
    exception when insufficient_privilege then
        perform pg_temp.ok('I2', 'un traslado no se puede modificar a mano');
    end;
end $$;

select set_config('request.jwt.claims', '', true);

-- ── Nada histórico ha cambiado ───────────────────────────────
do $$
declare f text := '';
begin
    if (select count(*) from pg_policies where schemaname='public'
         and tablename in ('profiles','groups','group_members','expenses','settlements')) <> 19
       then f := f || ' splitwise<>19;'; end if;
    if (select count(*) from pg_policies where schemaname='public'
         and tablename in ('profiles','groups','group_members','expenses','settlements')
         and (qual='true' or with_check='true')) <> 0 then f := f || ' splitwise_abiertas;'; end if;
    if (select count(*) from pg_policies where schemaname='public'
         and tablename in ('viajes','viaje_diario','viaje_fotos')) <> 12
       then f := f || ' viajes<>12;'; end if;
    if (select count(*) from pg_policies where schemaname='public'
         and tablename in ('viajes','viaje_diario','viaje_fotos')
         and (qual='true' or with_check='true')) <> 0 then f := f || ' viajes_abiertas;'; end if;
    if (select count(*) from public.viajes_acceso) <> 2 then f := f || ' accesos<>2;'; end if;
    if ((select count(*) from public.viajes), (select count(*) from public.viaje_diario),
        (select count(*) from public.viaje_fotos)) <> (3::bigint,2::bigint,8::bigint)
       then f := f || ' viajes<>3/2/8;'; end if;
    if (select count(*) from public.group_members) <> 6 then f := f || ' membresias<>6;'; end if;

    -- Invariantes, no recuentos congelados.
    if (select count(*) from public.expenses e where not exists
          (select 1 from public.groups g where g.id = e.group_id)) <> 0
       then f := f || ' gastos_sin_grupo;'; end if;
    if (select count(*) from public.expenses e where not exists
          (select 1 from public.group_members m
            where m.group_id=e.group_id and m.user_id=e.paid_by)) <> 0
       then f := f || ' pagadores_fuera;'; end if;
    if (select count(*) from public.groups g where not exists
          (select 1 from public.group_members m
            where m.group_id=g.id and m.role='owner')) <> 0
       then f := f || ' grupos_sin_propietario;'; end if;
    if (select count(*) from (select client_id from public.expenses
          where client_id is not null group by client_id having count(*)>1) d) <> 0
       then f := f || ' client_id_duplicados;'; end if;

    if f <> '' then raise exception 'INVARIANTES ROTOS:%', f; end if;
    perform pg_temp.ok('H1', 'Splitwise con sus 19 cerradas, Viajes con 12 cerradas, 2 accesos y 3/2/8');
    perform pg_temp.ok('H2', 'sin huérfanos, sin duplicados y sin pertenencias imposibles');
end $$;

do $$
declare n integer;
begin
    select count(*) into n from comprobado;
    raise notice 'Validación de 0007: % comprobaciones superadas', n;
    if n < 12 then
        raise exception 'Se esperaban al menos 12 comprobaciones y solo corrieron %', n;
    end if;
end $$;

-- Todo lo de esta transacción se deshace: los ataques y el traslado de
-- 0,01 € de la prueba de idempotencia NO quedan en producción.
rollback;

select 'Validación de 0007 correcta · nada de lo probado ha quedado escrito' as resultado;
