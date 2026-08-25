-- ============================================================
-- Invariantes de integridad · SOLO LECTURA
--
--     psql "$URL" -v ON_ERROR_STOP=1 -f supabase/pruebas/100_invariantes.sql
--
-- Sirve para CI y también para PRODUCCIÓN, que es lo que lo distingue del
-- resto del banco: aquí no hay ni un recuento fijo.
--
-- Por qué existe. La validación posterior a `0006` afirmaba
-- `expenses = 53`. En producción eso falló, y no porque hubiera daño: Dani
-- había apuntado un gasto legítimo ese mismo día. Un recuento congelado no
-- es integridad, es una foto — y sobre una base viva convierte el uso normal
-- de la aplicación en una alarma. Peor aún, invita a «arreglarlo» subiendo
-- el número, con lo que la comprobación deja de comprobar nada.
--
-- Lo que sí se puede exigir siempre, use la pareja la aplicación o no:
--
--   · ningún gasto puede quedar sin grupo;
--   · nadie puede pagar un gasto de un grupo al que no pertenece;
--   · ninguna parte de una liquidación puede estar fuera de su grupo;
--   · ningún grupo puede quedarse sin propietario;
--   · ningún `client_id` puede repetirse — así se detectaría una duplicación
--     por reintento de la cola offline;
--   · ninguna tabla de gastos puede quedar sin RLS ni con una política `true`.
--
-- Eso es lo que rompería una pérdida, una duplicación o una orfandad, y no
-- lo mueve ni un gasto nuevo ni cien.
-- ============================================================
\set ON_ERROR_STOP on

begin read only;

select
  (select count(*) from public.profiles)      as profiles,
  (select count(*) from public.groups)        as groups,
  (select count(*) from public.expenses)      as expenses,
  (select count(*) from public.settlements)   as settlements,
  (select count(*) from public.group_members) as group_members;

do $$
declare
    fallos text := '';
    n      bigint;
begin
    -- ── Referencial ──
    select count(*) into n from public.expenses e
     where not exists (select 1 from public.groups g where g.id = e.group_id);
    if n <> 0 then fallos := fallos || format(' %s gasto(s) sin grupo;', n); end if;

    select count(*) into n from public.expenses e
     where not exists (select 1 from public.profiles p where p.id = e.paid_by);
    if n <> 0 then fallos := fallos || format(' %s gasto(s) con pagador inexistente;', n); end if;

    select count(*) into n from public.settlements s
     where not exists (select 1 from public.groups g where g.id = s.group_id);
    if n <> 0 then fallos := fallos || format(' %s liquidación(es) sin grupo;', n); end if;

    -- ── Pertenencia ──
    select count(*) into n from public.expenses e
     where not exists (select 1 from public.group_members m
                        where m.group_id = e.group_id and m.user_id = e.paid_by);
    if n <> 0 then fallos := fallos || format(' %s gasto(s) pagados por alguien ajeno al grupo;', n); end if;

    select count(*) into n from public.settlements s
     where not exists (select 1 from public.group_members m
                        where m.group_id = s.group_id and m.user_id = s.from_user)
        or not exists (select 1 from public.group_members m
                        where m.group_id = s.group_id and m.user_id = s.to_user);
    if n <> 0 then fallos := fallos || format(' %s liquidación(es) con parte ajena al grupo;', n); end if;

    select count(*) into n from public.groups g
     where not exists (select 1 from public.group_members m
                        where m.group_id = g.id and m.role = 'owner');
    if n <> 0 then fallos := fallos || format(' %s grupo(s) sin propietario;', n); end if;

    -- ── Duplicación ──
    select count(*) into n from (
        select client_id from public.expenses
         where client_id is not null group by client_id having count(*) > 1) d;
    if n <> 0 then fallos := fallos || format(' %s client_id repetido(s) en gastos;', n); end if;

    select count(*) into n from (
        select client_id from public.settlements
         where client_id is not null group by client_id having count(*) > 1) d;
    if n <> 0 then fallos := fallos || format(' %s client_id repetido(s) en liquidaciones;', n); end if;

    -- ── Seguridad ──
    select count(*) into n from pg_tables
     where schemaname = 'public'
       and tablename in ('profiles','groups','group_members','expenses','settlements')
       and not rowsecurity;
    if n <> 0 then fallos := fallos || format(' %s tabla(s) de gastos sin RLS;', n); end if;

    select count(*) into n from pg_policies
     where schemaname = 'public'
       and tablename in ('profiles','groups','group_members','expenses','settlements')
       and (qual = 'true' or with_check = 'true');
    if n <> 0 then fallos := fallos || format(' %s política(s) abiertas en gastos;', n); end if;

    -- ── Coherencia mínima: la base no puede estar vacía por sorpresa ──
    if (select count(*) from public.groups) = 0 then
        fallos := fallos || ' no queda ni un grupo;';
    end if;
    if (select count(*) from public.profiles) = 0 then
        fallos := fallos || ' no queda ni un perfil;';
    end if;

    if fallos <> '' then
        raise exception E'INVARIANTES ROTOS:%', fallos;
    end if;

    raise notice 'Invariantes correctos: sin huérfanos, sin duplicados, sin pertenencias imposibles, RLS cerrada.';
end $$;

commit;

select 'Invariantes de integridad correctos' as resultado;
