-- ============================================================
-- Resultado del backfill: los dos perfiles, miembros y propietarios de los
-- tres grupos. Y nada más.
-- ============================================================
\set ON_ERROR_STOP on

do $$
declare
    fila record;
    total integer;
begin
    select count(*) into total from public.group_members;
    if total <> 6 then
        raise exception 'Se esperaban 6 membresías (3 grupos × 2 personas) y hay %', total;
    end if;

    for fila in
        select g.name,
               count(m.user_id)                                   as miembros,
               count(*) filter (where m.role = 'owner')            as owners,
               count(*) filter (where p.color = 'laurel')          as dani,
               count(*) filter (where p.color = 'buganvilla')      as pilar
        from public.groups g
        join public.group_members m on m.group_id = g.id
        join public.profiles p on p.id = m.user_id
        group by g.name
        order by g.name
    loop
        if fila.miembros <> 2 or fila.owners <> 2 or fila.dani <> 1 or fila.pilar <> 1 then
            raise exception
                'El grupo "%" no ha quedado con Dani y Pilar como propietarios: % miembros, % owners',
                fila.name, fila.miembros, fila.owners;
        end if;
        raise notice '[BF] ok — "%": Dani y Pilar, los dos propietarios', fila.name;
    end loop;

    raise notice '[BF] ok — backfill idempotente: sigue habiendo % membresías', total;
end $$;

-- Y los dos usuarios ven de verdad sus tres grupos.
set local role authenticated;

do $$
declare
    id_dani  uuid;
    id_pilar uuid;
begin
    -- Los ids se resuelven aquí dentro y no se imprimen.
    select id into id_dani  from public.profiles where color = 'laurel';
    select id into id_pilar from public.profiles where color = 'buganvilla';

    perform set_config('request.jwt.claims',
                       json_build_object('sub', id_dani)::text, true);
    if (select count(*) from public.groups) <> 3 then
        raise exception 'Dani debería ver sus 3 grupos y ve %',
            (select count(*) from public.groups);
    end if;
    raise notice '[BF] ok — Dani ve sus 3 grupos';

    perform set_config('request.jwt.claims',
                       json_build_object('sub', id_pilar)::text, true);
    if (select count(*) from public.groups) <> 3 then
        raise exception 'Pilar debería ver sus 3 grupos y ve %',
            (select count(*) from public.groups);
    end if;
    raise notice '[BF] ok — Pilar ve sus 3 grupos';
end $$;

reset role;

select 'Backfill correcto e idempotente' as resultado;
