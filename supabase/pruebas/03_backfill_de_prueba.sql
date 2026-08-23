-- ============================================================
-- Backfill de PRUEBA para el escenario de actualización.
--
-- El backfill real (`0002b_backfill_pertenencia.sql`) sigue SIN rellenar a
-- propósito: depende de que Dani confirme quién pertenece a cada grupo real,
-- y sus comprobaciones se niegan a dejar un grupo sin miembros. Eso está
-- probado aparte.
--
-- Este archivo rellena la pertenencia de los grupos del FIXTURE, para poder
-- seguir aplicando el resto de migraciones y ejecutar los ataques. Reproduce
-- la propuesta para grupos históricos compartidos: las dos personas dentro, y
-- las dos como propietarias, porque `created_by` no existía y no se puede
-- saber quién creó cada grupo.
--
-- Solo CI. Nunca contra una base real.
-- ============================================================
\set ON_ERROR_STOP on

insert into public.group_members (group_id, user_id, role)
select g.id, p.id, 'owner'
from public.groups g
cross join (values
    ('11111111-1111-1111-1111-111111111111'::uuid),
    ('22222222-2222-2222-2222-222222222222'::uuid)
) as p(id)
on conflict do nothing;

-- Las mismas cuatro comprobaciones que exige el backfill real.
do $$
declare
    sin_miembros text;
    sin_owner    text;
    fuera_gastos integer;
    fuera_liquid integer;
begin
    select string_agg(g.name, ', ') into sin_miembros
    from public.groups g
    where not exists (select 1 from public.group_members m where m.group_id = g.id);
    if sin_miembros is not null then
        raise exception 'Grupos sin miembros: %', sin_miembros;
    end if;

    select string_agg(g.name, ', ') into sin_owner
    from public.groups g
    where not exists (select 1 from public.group_members m
                      where m.group_id = g.id and m.role = 'owner');
    if sin_owner is not null then
        raise exception 'Grupos sin propietario: %', sin_owner;
    end if;

    select count(*) into fuera_gastos
    from public.expenses e
    where not exists (select 1 from public.group_members m
                      where m.group_id = e.group_id and m.user_id = e.paid_by);
    if fuera_gastos > 0 then
        raise exception '% gastos con pagador ajeno a su grupo', fuera_gastos;
    end if;

    select count(*) into fuera_liquid
    from public.settlements s
    where not exists (select 1 from public.group_members m
                      where m.group_id = s.group_id and m.user_id = s.from_user)
       or not exists (select 1 from public.group_members m
                      where m.group_id = s.group_id and m.user_id = s.to_user);
    if fuera_liquid > 0 then
        raise exception '% liquidaciones con alguna parte ajena a su grupo', fuera_liquid;
    end if;

    raise notice 'Backfill de prueba: % membresías en % grupos',
        (select count(*) from public.group_members),
        (select count(*) from public.groups);
end $$;
