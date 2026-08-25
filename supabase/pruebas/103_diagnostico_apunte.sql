-- ============================================================
-- Diagnóstico del apunte manual «Deuda Dani 225,60» · SOLO LECTURA
--
-- Prepara la corrección; NO la ejecuta. No borra el gasto ni traslada nada.
--
-- Qué NO se imprime: correos, UUID, notas, ni el concepto de ningún gasto
-- que no sea el que se busca. Las personas se identifican por el color de su
-- perfil, que es el alias que ya usa todo el proyecto. Los gastos, por un
-- resorte corto derivado de su id, suficiente para señalar cuál es sin
-- publicar el identificador.
-- ============================================================
\set ON_ERROR_STOP on

begin read only;

\echo '════ 1 · Saldos reales, en céntimos ════'
-- Signo respecto a la primera persona de la pareja (la de perfil más
-- antiguo): > 0 significa que la otra le debe.
select g.name                                                   as grupo,
       public.saldo_centimos(g.id, (public.pareja_del_grupo(g.id))[1],
                                   (public.pareja_del_grupo(g.id))[2]) as saldo_centimos,
       (select color from public.profiles
         where id = (public.pareja_del_grupo(g.id))[1])          as alias_referencia
  from public.groups g
 where g.name in ('Slovenia', 'Bierzo & Asturias')
 order by g.name;

\echo '════ 2 · El apunte buscado ════'
-- Se buscan los gastos de Bierzo cuyo concepto hable de deuda. Se imprime su
-- concepto porque ES el apunte que se busca; ningún otro.
select left(md5(e.id::text), 8)                        as resorte,
       e.description                                   as concepto,
       round(e.amount * 100)::bigint                   as importe_centimos,
       e.payer_share                                   as reparto,
       (select color from public.profiles where id = e.paid_by) as alias_pagador,
       e.spent_on                                      as fecha,
       e.category                                      as categoria,
       (e.client_id is not null)                       as tiene_client_id,
       (e.created_at at time zone 'UTC')::date         as creado
  from public.expenses e
  join public.groups g on g.id = e.group_id
 where g.name = 'Bierzo & Asturias'
   and e.description ~* 'deuda'
 order by e.created_at;

\echo '════ 3 · ¿Cuántos coinciden exactamente? ════'
select count(*) filter (where e.description ~* 'deuda')                        as con_concepto_deuda,
       count(*) filter (where round(e.amount * 100) = 22560)                   as con_importe_22560,
       count(*) filter (where e.description ~* 'deuda'
                          and round(e.amount * 100) = 22560)                   as coincidencia_exacta
  from public.expenses e
  join public.groups g on g.id = e.group_id
 where g.name = 'Bierzo & Asturias';

\echo '════ 4 · ¿Está vinculado a algún traslado? ════'
-- Un gasto nunca puede estarlo —el vínculo vive en `settlements`—, pero se
-- comprueba explícitamente para poder afirmarlo.
select (to_regclass('public.balance_transfers') is not null)                   as existe_tabla_traslados,
       coalesce((select count(*) from public.balance_transfers), 0)            as traslados_totales,
       coalesce((select count(*) from public.settlements s
                  join public.groups g on g.id = s.group_id
                 where g.name in ('Slovenia','Bierzo & Asturias')
                   and s.transfer_id is not null), 0)                          as liquidaciones_de_traslado;

\echo '════ 5 · Total gastado de Bierzo, en céntimos ════'
select round(sum(e.amount) * 100)::bigint                    as total_gastado_centimos,
       count(*)                                              as numero_de_gastos,
       round(sum(e.amount) * 100)::bigint - 22560            as total_si_se_quita_el_apunte
  from public.expenses e
  join public.groups g on g.id = e.group_id
 where g.name = 'Bierzo & Asturias';

\echo '════ 6 · Liquidaciones de los dos grupos ════'
select g.name                                    as grupo,
       count(s.id)                               as liquidaciones,
       coalesce(round(sum(s.amount) * 100), 0)::bigint as suma_centimos,
       count(s.id) filter (where s.transfer_id is not null) as de_traslado
  from public.groups g
  left join public.settlements s on s.group_id = g.id
 where g.name in ('Slovenia', 'Bierzo & Asturias')
 group by g.name order by g.name;

\echo '════ 7 · Pertenencia e integridad ════'
select g.name                                                            as grupo,
       (select count(*) from public.group_members m where m.group_id = g.id)  as miembros,
       (select count(*) from public.group_members m
         where m.group_id = g.id and m.role = 'owner')                   as propietarios,
       (public.pareja_del_grupo(g.id) is not null)                       as es_par,
       (select count(*) from public.expenses e
         where e.group_id = g.id and not exists
           (select 1 from public.group_members m
             where m.group_id = e.group_id and m.user_id = e.paid_by))   as pagadores_fuera
  from public.groups g
 where g.name in ('Slovenia', 'Bierzo & Asturias')
 order by g.name;

\echo '════ 8 · ¿Los dos grupos tienen LA MISMA pareja? ════'
select (public.pareja_del_grupo((select id from public.groups where name = 'Slovenia'))
        = public.pareja_del_grupo((select id from public.groups where name = 'Bierzo & Asturias')))
       as misma_pareja;

\echo '════ 9 · Qué pasaría con el traslado, en céntimos ════'
-- Solo aritmética sobre lo leído. No escribe nada.
with s as (
    select public.saldo_centimos(id, (public.pareja_del_grupo(id))[1],
                                     (public.pareja_del_grupo(id))[2]) as c
      from public.groups where name = 'Slovenia'),
b as (
    select public.saldo_centimos(id, (public.pareja_del_grupo(id))[1],
                                     (public.pareja_del_grupo(id))[2]) as c
      from public.groups where name = 'Bierzo & Asturias')
select (select c from s)                            as slovenia_ahora,
       (select c from b)                            as bierzo_ahora,
       (select c from s) + (select c from b)         as suma_ahora,
       0                                            as slovenia_despues,
       (select c from s) + (select c from b)         as bierzo_despues_si_no_se_toca_el_gasto;

commit;
