-- ============================================================
-- Huella de los datos · SOLO LECTURA
--
-- Imprime un resumen estable de todo lo que un cambio de esquema NO debería
-- tocar: recuentos, sumas, un md5 del contenido de cada tabla y los saldos
-- reales grupo a grupo.
--
-- Para qué sirve: ejecutarlo ANTES y DESPUÉS de aplicar una migración y
-- comparar las dos salidas con `diff`. Si son idénticas, no se ha movido un
-- solo dato ni un solo céntimo.
--
-- Los `id` de `expenses` y `settlements` quedan FUERA del md5 a propósito:
-- los genera `gen_random_uuid()`, así que difieren entre dos bases recreadas
-- desde el mismo fixture y darían una diferencia que no significa nada. Lo
-- que se compara es el contenido: grupo, pagador, importe, reparto y fecha.
--
-- No escribe nada. Se puede ejecutar contra producción.
-- ============================================================
\pset format unaligned
\pset tuples_only on

select 'perfiles='   || count(*) from public.profiles;
select 'grupos='     || count(*) from public.groups;
select 'miembros='   || count(*) from public.group_members;
select 'gastos='     || count(*) from public.expenses;
select 'liquid='     || count(*) from public.settlements;
select 'traslados='  || count(*) from public.balance_transfers;
select 'sumagastos=' || coalesce(sum(amount)::text, '0') from public.expenses;
select 'sumaliquid=' || coalesce(sum(amount)::text, '0') from public.settlements;

select 'md5expenses=' || md5(string_agg(t, '|' order by t)) from (
  select g.name || ':' || e.paid_by || ':' || e.amount || ':' || e.payer_share
         || ':' || e.spent_on || ':' || e.description || ':' || e.category
         || ':' || coalesce(e.client_id, '') as t
    from public.expenses e join public.groups g on g.id = e.group_id) x;

select 'md5settlements=' || md5(string_agg(t, '|' order by t)) from (
  select g.name || ':' || s.from_user || ':' || s.to_user || ':' || s.amount
         || ':' || s.settled_on as t
    from public.settlements s join public.groups g on g.id = s.group_id) x;

select 'md5members='  || md5(string_agg(t, '|' order by t)) from (
  select group_id || ':' || user_id || ':' || role as t from public.group_members) x;

select 'md5groups='   || md5(string_agg(t, '|' order by t)) from (
  select id || ':' || name || ':' || coalesce(created_by::text, '-') as t
    from public.groups) x;

select 'md5profiles=' || md5(string_agg(t, '|' order by t)) from (
  select id || ':' || display_name || ':' || color as t from public.profiles) x;

-- Los saldos de verdad, con la misma función que usa la aplicación.
select 'saldo:' || g.name || '=' || public.saldo_centimos(g.id, p1.user_id, p2.user_id)
  from public.groups g
  join public.group_members p1 on p1.group_id = g.id
  join public.group_members p2 on p2.group_id = g.id and p2.user_id > p1.user_id
 order by g.name, p1.user_id, p2.user_id;
