-- ============================================================
-- Frontera con la aplicación de VIAJES · comprobación DESPUÉS de migrar
--
-- Vuelve a tomar la huella y la compara con la de 96. Cualquier diferencia
-- —una columna, una política, un índice, un trigger, la pertenencia a
-- Realtime o incluso el número de filas— hace fallar el trabajo.
-- ============================================================
\set ON_ERROR_STOP on

insert into public.frontera_instantanea (momento, clave, valor)
select 'despues', clave, valor from public.frontera_viajes();

do $$
declare
    desaparecidos text;
    aparecidos    text;
    n_antes       integer;
    n_despues     integer;
begin
    select count(*) into n_antes   from public.frontera_instantanea where momento = 'antes';
    select count(*) into n_despues from public.frontera_instantanea where momento = 'despues';

    -- Lo que había antes y ya no está
    select string_agg(clave || ' → ' || valor, E'\n  ') into desaparecidos
    from (
        select clave, valor from public.frontera_instantanea where momento = 'antes'
        except all
        select clave, valor from public.frontera_instantanea where momento = 'despues'
    ) d;

    -- Lo que ha aparecido y antes no estaba
    select string_agg(clave || ' → ' || valor, E'\n  ') into aparecidos
    from (
        select clave, valor from public.frontera_instantanea where momento = 'despues'
        except all
        select clave, valor from public.frontera_instantanea where momento = 'antes'
    ) d;

    if desaparecidos is not null then
        raise exception E'Las migraciones de gastos han DESTRUIDO algo de la aplicación de viajes:\n  %',
            desaparecidos;
    end if;

    if aparecidos is not null then
        raise exception E'Las migraciones de gastos han AÑADIDO algo a la aplicación de viajes:\n  %',
            aparecidos;
    end if;

    raise notice 'Frontera de viajes intacta: % elementos idénticos antes y después',
        n_antes;

    if n_antes <> n_despues then
        raise exception 'El recuento de la frontera no cuadra: % antes, % después',
            n_antes, n_despues;
    end if;
end $$;

select 'La aplicación de viajes ha quedado intacta' as resultado;
