-- ============================================================
-- Seguridad de la aplicación de VIAJES, con DML real
--
-- Se ejecuta DESPUÉS de 0006 sobre el escenario histórico. Suplanta a cada
-- cuenta con `set local role authenticated` + el `sub` del JWT, igual que
-- 98_seguridad_dml.sql, y comprueba lo que de verdad puede hacer cada una.
-- ============================================================
\set ON_ERROR_STOP on

begin;

-- Los recuentos de partida. En producción son 3/2/8; en el escenario del CI
-- son otros. Lo que se comprueba es que NO cambien, no un número concreto.
create temporary table recuentos_antes on commit drop as
select (select count(*) from public.viajes)       as viajes,
       (select count(*) from public.viaje_diario) as diario,
       (select count(*) from public.viaje_fotos)  as fotos;

-- La leen también las secciones que suplantan a una cuenta.
grant select on recuentos_antes to authenticated;

-- ── Un tercero que se acaba de registrar ─────────────────────
-- Se le crea la cuenta como haría el alta real: fila en auth.users, que
-- dispara el trigger y le crea su perfil. NO se le da acceso a viajes.
insert into auth.users (id, email, raw_user_meta_data)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc',
        'intruso.viajes@ejemplo.invalido',
        '{"display_name":"Intruso Viajes","color":"laurel"}'::jsonb)
on conflict (id) do nothing;

do $$
declare
    dani  uuid;
    pilar uuid;
    n     integer;
    ok    boolean;
begin
    select id into dani  from public.profiles where color = 'laurel'
     and id <> 'cccccccc-cccc-cccc-cccc-cccccccccccc' order by created_at limit 1;
    select id into pilar from public.profiles where color = 'buganvilla' limit 1;

    -- ── V01 · el backfill ha dado acceso exactamente a dos ──
    select count(*) into n from public.viajes_acceso;
    if n <> 2 then raise exception '[V01] FALLA — viajes_acceso tiene % filas, se esperaban 2', n; end if;
    if not exists (select 1 from public.viajes_acceso where user_id = dani)
       or not exists (select 1 from public.viajes_acceso where user_id = pilar) then
        raise exception '[V01] FALLA — el acceso no es de las dos personas esperadas';
    end if;
    raise notice '[V01] ok — acceso a viajes concedido exactamente a las dos personas que ya la usaban';

    -- ── V02 · registrarse NO concede acceso ──
    if exists (select 1 from public.viajes_acceso
                where user_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc') then
        raise exception '[V02] FALLA — registrarse ha concedido acceso a viajes';
    end if;
    if not exists (select 1 from public.profiles
                    where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc') then
        raise exception '[V02] FALLA — el alta no ha creado el perfil del tercero';
    end if;
    raise notice '[V02] ok — el tercero tiene perfil pero NO acceso a viajes';

    -- ── V03 · ninguna política abierta ──
    select count(*) into n from pg_policies
     where schemaname='public' and tablename in ('viajes','viaje_diario','viaje_fotos')
       and (qual='true' or with_check='true');
    if n <> 0 then raise exception '[V03] FALLA — quedan % políticas abiertas en viajes', n; end if;
    raise notice '[V03] ok — ninguna política de viajes usa `true`';

    -- ── V04 · las cuatro operaciones están cubiertas en las tres tablas ──
    select count(*) into n from pg_policies
     where schemaname='public' and tablename in ('viajes','viaje_diario','viaje_fotos');
    if n <> 12 then raise exception '[V04] FALLA — hay % políticas en viajes, se esperaban 12', n; end if;
    if exists (
        select 1 from (values ('viajes'),('viaje_diario'),('viaje_fotos')) t(nombre)
        cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) o(op)
        where not exists (select 1 from pg_policies p
                           where p.schemaname='public' and p.tablename=t.nombre and p.cmd=o.op)
    ) then
        raise exception '[V04] FALLA — falta cubrir alguna operación en alguna tabla de viajes';
    end if;
    raise notice '[V04] ok — SELECT, INSERT, UPDATE y DELETE cubiertos en las tres tablas';

    -- ── V05 · la función auxiliar es segura ──
    select p.prosecdef and p.proconfig::text like '%search_path=public%'
      into ok
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname='public' and p.proname='puede_viajes';
    if not coalesce(ok, false) then
        raise exception '[V05] FALLA — puede_viajes() no es SECURITY DEFINER con search_path fijo';
    end if;
    if exists (select 1 from information_schema.role_routine_grants
                where routine_schema='public' and routine_name='puede_viajes'
                  and grantee in ('PUBLIC','anon')) then
        raise exception '[V05] FALLA — puede_viajes() es ejecutable por PUBLIC o anon';
    end if;
    raise notice '[V05] ok — puede_viajes() es SECURITY DEFINER, search_path fijo, sin PUBLIC ni anon';
end $$;

-- ══ Dani: tiene acceso ═══════════════════════════════════════
do $$
declare dani uuid;
begin
    select id into dani from public.profiles where color='laurel'
     and id <> 'cccccccc-cccc-cccc-cccc-cccccccccccc' order by created_at limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', dani)::text, true);
end $$;
set local role authenticated;

do $$
declare v bigint; d bigint; f bigint;
begin
    select count(*) into v from public.viajes;
    select count(*) into d from public.viaje_diario;
    select count(*) into f from public.viaje_fotos;
    if (v,d,f) is distinct from (select (viajes,diario,fotos) from recuentos_antes) then
        raise exception '[V06] FALLA — Dani ve %/%/%, distinto de lo que había', v, d, f;
    end if;
    if v = 0 then raise exception '[V06] FALLA — el escenario no tiene viajes: la prueba no valdría'; end if;
    raise notice '[V06] ok — Dani sigue viendo todos los viajes, el diario y las fotos (%/%/%)', v, d, f;

    insert into public.viajes (id, nombre, dias) values ('prueba-dani', 'Prueba', '[]'::jsonb);
    update public.viajes set nombre = 'Prueba editada' where id = 'prueba-dani';
    delete from public.viajes where id = 'prueba-dani';
    raise notice '[V07] ok — Dani puede crear, editar y borrar viajes';
end $$;
reset role;

-- ══ Pilar: también ═══════════════════════════════════════════
do $$
declare pilar uuid;
begin
    select id into pilar from public.profiles where color='buganvilla' limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', pilar)::text, true);
end $$;
set local role authenticated;

do $$
declare v bigint; f bigint;
begin
    select count(*) into v from public.viajes;
    select count(*) into f from public.viaje_fotos;
    if (v,f) is distinct from (select (viajes,fotos) from recuentos_antes) then
        raise exception '[V08] FALLA — Pilar ve % viajes y % fotos, distinto de lo que había', v, f;
    end if;
    raise notice '[V08] ok — Pilar conserva el acceso: % viajes y % fotos', v, f;

    insert into public.viaje_fotos (id, viaje, dia, datos) values ('foto-pilar', 'v1', 1, 'x');
    delete from public.viaje_fotos where id = 'foto-pilar';
    raise notice '[V09] ok — Pilar puede escribir y borrar en viajes';

    -- Ve su propia fila de acceso, y SOLO la suya: la tabla no sirve para
    -- enumerar a los demás.
    if (select count(*) from public.viajes_acceso) <> 1 then
        raise exception '[V09b] FALLA — Pilar no ve exactamente una fila de viajes_acceso';
    end if;
    raise notice '[V09b] ok — Pilar ve su fila de acceso y solo la suya';
end $$;
reset role;

-- ══ El tercero: nada ═════════════════════════════════════════
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc"}', true);
set local role authenticated;

do $$
declare v bigint; d bigint; f bigint; a bigint; escrito integer;
begin
    select count(*) into v from public.viajes;
    select count(*) into d from public.viaje_diario;
    select count(*) into f from public.viaje_fotos;
    if (v,d,f) <> (0,0,0) then
        raise exception '[V10] FALLA — el tercero ve %/%/% y no debería ver nada', v, d, f;
    end if;
    raise notice '[V10] ok — un tercero autenticado no ve ningún viaje, día ni foto';

    -- No puede enumerar quién tiene acceso.
    select count(*) into a from public.viajes_acceso;
    if a <> 0 then
        raise exception '[V11] FALLA — el tercero ve % filas de viajes_acceso', a;
    end if;
    raise notice '[V11] ok — el tercero no puede enumerar quién tiene acceso';

    -- ATAQUE: autoconcederse acceso.
    begin
        insert into public.viajes_acceso (user_id)
        values ('cccccccc-cccc-cccc-cccc-cccccccccccc');
    exception when others then null;
    end;
    if public.puede_viajes() then
        raise exception '[V12] FALLA — el tercero se ha autoconcedido acceso a viajes';
    end if;
    raise notice '[V12] ok — ATAQUE: el tercero NO puede autoconcederse acceso';

    -- ATAQUE: escribir un viaje.
    begin
        insert into public.viajes (id, nombre, dias) values ('intruso', 'Intruso', '[]'::jsonb);
    exception when others then null;
    end;
    -- ATAQUE: escribir una foto y un día de diario.
    begin
        insert into public.viaje_fotos (id, viaje, dia, datos) values ('intruso-f', 'v1', 1, 'x');
    exception when others then null;
    end;
    begin
        insert into public.viaje_diario (viaje) values ('intruso-d');
    exception when others then null;
    end;
    raise notice '[V13] ok — ATAQUE: los INSERT del tercero no prosperan';

    -- ATAQUE: modificar y borrar lo ajeno. PostgREST no da error cuando
    -- afectan a cero filas, así que se cuenta lo afectado.
    update public.viajes set nombre = 'secuestrado';
    get diagnostics escrito = row_count;
    if escrito <> 0 then
        raise exception '[V14] FALLA — el tercero ha modificado % viaje(s)', escrito;
    end if;
    delete from public.viaje_fotos;
    get diagnostics escrito = row_count;
    if escrito <> 0 then
        raise exception '[V15] FALLA — el tercero ha borrado % foto(s)', escrito;
    end if;
    raise notice '[V14] ok — ATAQUE: el tercero no modifica ningún viaje';
    raise notice '[V15] ok — ATAQUE: el tercero no borra ninguna foto';
end $$;
reset role;

-- ══ Nada histórico ha cambiado ═══════════════════════════════
do $$
declare v bigint; d bigint; f bigint; g bigint; e bigint; s bigint; m bigint;
begin
    select count(*) into v from public.viajes;
    select count(*) into d from public.viaje_diario;
    select count(*) into f from public.viaje_fotos;
    if (v,d,f) is distinct from (select (viajes,diario,fotos) from recuentos_antes) then
        raise exception '[V16] FALLA — los datos de viajes han cambiado: %/%/%', v, d, f;
    end if;
    raise notice '[V16] ok — viajes intacta: % viajes, % días de diario, % fotos', v, d, f;

    select count(*) into g from public.groups;
    select count(*) into e from public.expenses;
    select count(*) into s from public.settlements;
    select count(*) into m from public.group_members;
    if (g,e,s,m) <> (3,53,1,6) then
        raise exception '[V17] FALLA — Splitwise ha cambiado: %/%/%/%', g, e, s, m;
    end if;
    raise notice '[V17] ok — Splitwise intacto: 3 grupos, 53 gastos, 1 liquidación, 6 membresías';
    -- El alta del tercero SÍ crea su perfil: eso es correcto y no da acceso.

    select count(*) into g from pg_policies where schemaname='public'
       and tablename in ('profiles','groups','group_members','expenses','settlements');
    if g <> 19 then
        raise exception '[V18] FALLA — Splitwise tiene % políticas, se esperaban 19', g;
    end if;
    select count(*) into g from pg_policies where schemaname='public'
       and tablename in ('profiles','groups','group_members','expenses','settlements')
       and (qual='true' or with_check='true');
    if g <> 0 then
        raise exception '[V18] FALLA — han reaparecido % políticas abiertas en Splitwise', g;
    end if;
    raise notice '[V18] ok — las 19 políticas de Splitwise siguen, y ninguna abierta';

    -- Viajes no se publica en Realtime: la aplicación no lo usa.
    select count(*) into g from pg_publication_tables
     where tablename in ('viajes','viaje_diario','viaje_fotos');
    if g <> 0 then
        raise exception '[V19] FALLA — se han publicado % tabla(s) de viajes en Realtime', g;
    end if;
    raise notice '[V19] ok — ninguna tabla de viajes publicada en Realtime';
end $$;

rollback;

select 'Seguridad de viajes: 19 aserciones superadas' as resultado;
