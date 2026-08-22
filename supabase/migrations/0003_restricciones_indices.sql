-- ============================================================
-- 0003 · Claves foráneas, unicidad, restricciones e índices
--
-- NO APLICADA. Algunas sentencias PUEDEN FALLAR si los datos actuales las
-- incumplen. Eso es deliberado: es preferible que falle la migración a que
-- se aplique con datos inconsistentes. supabase/README.md §5 tiene las
-- consultas de comprobación previa para cada una.
-- ============================================================

-- ------------------------------------------------------------
-- Unicidad de client_id
--
-- La aplicación usa `upsert(..., { onConflict: 'client_id' })` para que la
-- cola offline y la importación de CSV sean idempotentes. SIN ESTE ÍNDICE
-- ese upsert falla, y el resultado es DUPLICACIÓN DE GASTOS al sincronizar.
-- Es la restricción más importante de este archivo.
--
-- El índice NO puede ser parcial. PostgREST traduce `onConflict: 'client_id'`
-- a `ON CONFLICT (client_id)` sin cláusula WHERE, y PostgreSQL solo puede
-- inferir un índice parcial si la sentencia repite su predicado. Con un
-- índice parcial, el upsert fallaría con "no unique or exclusion constraint
-- matching the ON CONFLICT specification".
--
-- Un índice único normal ya permite tantas filas con client_id NULL como
-- haga falta: en PostgreSQL dos NULL nunca se consideran iguales. Así que
-- las filas creadas a mano sin client_id siguen conviviendo sin problema.
--
-- Comprobar antes:
--   select client_id, count(*) from public.expenses
--   where client_id is not null group by client_id having count(*) > 1;
-- Si devuelve filas, hay duplicados que deduplicar ANTES (ver
-- docs/PLAN-MIGRACION-DATOS.md §3).
-- ------------------------------------------------------------
create unique index if not exists uq_expenses_client_id
    on public.expenses (client_id);

create unique index if not exists uq_settlements_client_id
    on public.settlements (client_id);

-- ------------------------------------------------------------
-- Claves foráneas
--
-- Comprobar antes que no hay huérfanos:
--   select count(*) from public.expenses e
--   left join public.groups g on g.id = e.group_id where g.id is null;
-- ------------------------------------------------------------
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'fk_expenses_group') then
        alter table public.expenses
            add constraint fk_expenses_group
            foreign key (group_id) references public.groups(id) on delete cascade;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'fk_expenses_payer') then
        alter table public.expenses
            add constraint fk_expenses_payer
            foreign key (paid_by) references public.profiles(id) on delete restrict;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'fk_settlements_group') then
        alter table public.settlements
            add constraint fk_settlements_group
            foreign key (group_id) references public.groups(id) on delete cascade;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'fk_settlements_from') then
        alter table public.settlements
            add constraint fk_settlements_from
            foreign key (from_user) references public.profiles(id) on delete restrict;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'fk_settlements_to') then
        alter table public.settlements
            add constraint fk_settlements_to
            foreign key (to_user) references public.profiles(id) on delete restrict;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'fk_groups_creador') then
        alter table public.groups
            add constraint fk_groups_creador
            foreign key (created_by) references public.profiles(id) on delete set null;
    end if;
end $$;

-- ------------------------------------------------------------
-- Restricciones de dominio
--
-- Se añaden como NOT VALID: se aplican a lo nuevo desde ya, pero no
-- comprueban las filas existentes, así que la migración no puede fallar
-- por datos históricos. La validación se hace después, a mano, cuando se
-- haya comprobado que no hay filas que las incumplan (README §5).
-- ------------------------------------------------------------
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_expenses_importe_positivo') then
        alter table public.expenses
            add constraint ck_expenses_importe_positivo check (amount > 0) not valid;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'ck_expenses_reparto') then
        alter table public.expenses
            add constraint ck_expenses_reparto
            check (payer_share >= 0 and payer_share <= 1) not valid;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'ck_settlements_importe_positivo') then
        alter table public.settlements
            add constraint ck_settlements_importe_positivo check (amount > 0) not valid;
    end if;

    if not exists (select 1 from pg_constraint where conname = 'ck_settlements_personas_distintas') then
        alter table public.settlements
            add constraint ck_settlements_personas_distintas
            check (from_user <> to_user) not valid;
    end if;
end $$;

-- Cuando las comprobaciones del README §5 den 0 filas, ejecutar a mano:
--   alter table public.expenses    validate constraint ck_expenses_importe_positivo;
--   alter table public.expenses    validate constraint ck_expenses_reparto;
--   alter table public.settlements validate constraint ck_settlements_importe_positivo;
--   alter table public.settlements validate constraint ck_settlements_personas_distintas;

-- ------------------------------------------------------------
-- Índices de consulta
--
-- La app pide siempre por grupo y ordena por fecha descendente. Estos
-- índices son los que hacen que la paginación completa (que sustituye al
-- limit(2500)) siga siendo rápida cuando haya decenas de miles de filas.
-- ------------------------------------------------------------
create index if not exists idx_expenses_grupo_fecha
    on public.expenses (group_id, spent_on desc, created_at desc);

create index if not exists idx_expenses_pagador
    on public.expenses (paid_by);

create index if not exists idx_settlements_grupo_fecha
    on public.settlements (group_id, settled_on desc, created_at desc);

create index if not exists idx_settlements_personas
    on public.settlements (from_user, to_user);

-- Para el "borrar lo importado" (client_id like 'imp:%').
create index if not exists idx_expenses_client_prefijo
    on public.expenses (group_id, client_id text_pattern_ops);
