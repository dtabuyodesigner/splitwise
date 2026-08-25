-- ============================================================
-- Tras un backfill abortado: ¿se ha deshecho TODO?
--
-- Se ejecuta después de que el lote atómico (0002 + 0002b) haya fallado a
-- propósito. Lo que comprueba es que no queda NADA a medias:
--
--   · `group_members` no llega a existir. Es lo más importante: si quedara
--     creada y vacía, la aplicación dejaría de enseñar los grupos históricos,
--     porque el frontend distingue "tabla ausente" (comportamiento anterior)
--     de "tabla vacía" (la pertenencia manda, y no pertenecer es no ver).
--   · los datos históricos siguen exactamente como estaban;
--   · lo que insertó el escenario negativo también se ha deshecho.
-- ============================================================
\set ON_ERROR_STOP on

do $$
declare
    n_grupos    integer;
    n_perfiles  integer;
    n_gastos    integer;
    n_liquid    integer;
    n_colores   integer;
    nombres     text;
begin
    -- 1 · La tabla no debe existir. Es la comprobación que da sentido a todo
    --     el lote atómico.
    if to_regclass('public.group_members') is not null then
        raise exception
            'ROLLBACK INCOMPLETO: group_members existe tras abortar el backfill'
            using hint = '0002 se ha confirmado sin 0002b. En ese estado la aplicación '
                         'no enseñaría ningún grupo histórico.';
    end if;

    -- 2 · Y tampoco las funciones y triggers que crea 0002.
    if to_regprocedure('public.es_miembro(uuid, uuid)') is not null
       or to_regprocedure('public.es_owner(uuid, uuid)') is not null then
        raise exception
            'ROLLBACK INCOMPLETO: han quedado funciones de 0002 (es_miembro / es_owner)';
    end if;

    if exists (
        select 1 from pg_trigger t
        join pg_class rel on rel.oid = t.tgrelid
        where rel.relname = 'groups'
          and t.tgname in ('antes_de_crear_grupo', 'tras_crear_grupo')
          and not t.tgisinternal
    ) then
        raise exception 'ROLLBACK INCOMPLETO: han quedado triggers de 0002 sobre groups';
    end if;

    -- 3 · Los datos históricos, intactos.
    select count(*) into n_grupos   from public.groups;
    select count(*) into n_perfiles from public.profiles;
    select count(*) into n_gastos   from public.expenses;
    select count(*) into n_liquid   from public.settlements;

    if n_grupos <> 3 then
        raise exception
            'ROLLBACK INCOMPLETO: hay % grupos y debería haber 3 (¿quedó el del escenario negativo?)',
            n_grupos;
    end if;
    if n_perfiles <> 2 then
        raise exception
            'ROLLBACK INCOMPLETO: hay % perfiles y debería haber 2 (¿quedó el tercero?)',
            n_perfiles;
    end if;
    if n_gastos <> 53 then
        raise exception 'ROLLBACK INCOMPLETO: hay % gastos y debería haber 53', n_gastos;
    end if;
    if n_liquid <> 1 then
        raise exception 'ROLLBACK INCOMPLETO: hay % liquidaciones y debería haber 1', n_liquid;
    end if;

    -- 4 · Los grupos siguen siendo exactamente los tres esperados.
    select string_agg(name, ', ' order by name) into nombres from public.groups;
    if nombres <> 'Bierzo & Asturias, Casa, Slovenia' then
        raise exception 'ROLLBACK INCOMPLETO: los grupos son "%"', nombres;
    end if;

    -- 5 · Y los perfiles conservan sus colores distintos: el escenario
    --     "colores_ambiguos" los igualaba, y eso también debe haberse deshecho.
    select count(distinct color) into n_colores from public.profiles;
    if n_colores <> 2 then
        raise exception
            'ROLLBACK INCOMPLETO: los perfiles tienen % colores distintos y deberían tener 2',
            n_colores;
    end if;

    raise notice
        '[RB] ok — rollback completo: group_members NO existe, y siguen 3 grupos, 2 perfiles con colores distintos, 53 gastos y 1 liquidación';
end $$;

select 'El lote atómico se ha deshecho por completo' as resultado;
