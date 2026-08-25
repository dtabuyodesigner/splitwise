-- ============================================================
-- Frontera con la aplicación de VIAJES · comprobación DESPUÉS de migrar
--
-- Vuelve a tomar la huella y la compara con la de 96. Cualquier diferencia
-- —una columna, un índice, un trigger, una función, un privilegio, la
-- pertenencia a Realtime o incluso el número de filas— hace fallar el trabajo.
--
-- Las POLÍTICAS son la única excepción, y desde 0006: esa migración retira a
-- propósito las doce `using (true)` que dejaban la aplicación de viajes
-- abierta a cualquier cuenta registrada, y pone doce cerradas en su lugar.
-- Comparar políticas aquí solo diría «han cambiado», que ya lo sabemos. Lo
-- que de verdad hay que comprobar —que son exactamente doce, que ninguna usa
-- `true`, y que Dani y Pilar conservan el acceso mientras un tercero no ve
-- nada— lo hace 97b_seguridad_viajes.sql con DML real.
--
-- El resto de la frontera sigue siendo estricto: si 0006 tocara una columna,
-- un índice o una fila de viajes, este archivo lo cazaría.
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
    select count(*) into n_antes   from public.frontera_instantanea
     where momento = 'antes'   and clave not like 'politica%';
    select count(*) into n_despues from public.frontera_instantanea
     where momento = 'despues' and clave not like 'politica%';

    -- Lo que había antes y ya no está
    select string_agg(clave || ' → ' || valor, E'\n  ') into desaparecidos
    from (
        select clave, valor from public.frontera_instantanea
         where momento = 'antes'   and clave not like 'politica%'
        except all
        select clave, valor from public.frontera_instantanea
         where momento = 'despues' and clave not like 'politica%'
    ) d;

    -- Lo que ha aparecido y antes no estaba
    select string_agg(clave || ' → ' || valor, E'\n  ') into aparecidos
    from (
        select clave, valor from public.frontera_instantanea
         where momento = 'despues' and clave not like 'politica%'
        except all
        select clave, valor from public.frontera_instantanea
         where momento = 'antes'   and clave not like 'politica%'
    ) d;

    if desaparecidos is not null then
        raise exception E'Las migraciones de gastos han DESTRUIDO algo de la aplicación de viajes:\n  %',
            desaparecidos;
    end if;

    if aparecidos is not null then
        raise exception E'Las migraciones de gastos han AÑADIDO algo a la aplicación de viajes:\n  %',
            aparecidos;
    end if;

    raise notice 'Frontera de viajes intacta: % elementos idénticos antes y después (políticas aparte)',
        n_antes;

    if n_antes <> n_despues then
        raise exception 'El recuento de la frontera no cuadra: % antes, % después',
            n_antes, n_despues;
    end if;
end $$;

-- Las políticas sí han cambiado, y tienen que haberlo hecho: doce abiertas
-- antes, doce cerradas después.
do $politicas$
declare
    abiertas_antes   integer;
    abiertas_despues integer;
    total_despues    integer;
begin
    select count(*) into abiertas_antes from public.frontera_instantanea
     where momento = 'antes' and clave like 'politica%' and valor like '%using=true%';

    select count(*) into abiertas_despues from pg_policies
     where schemaname = 'public' and tablename in ('viajes','viaje_diario','viaje_fotos')
       and (qual = 'true' or with_check = 'true');

    select count(*) into total_despues from pg_policies
     where schemaname = 'public' and tablename in ('viajes','viaje_diario','viaje_fotos');

    if abiertas_despues > 0 then
        raise exception 'Siguen abiertas % política(s) de viajes tras migrar', abiertas_despues;
    end if;
    if total_despues <> 12 then
        raise exception 'Viajes tiene % políticas tras migrar, se esperaban 12', total_despues;
    end if;

    raise notice 'Políticas de viajes: % abiertas antes → 0 abiertas después, 12 cerradas',
        abiertas_antes;
end
$politicas$;

select 'La aplicación de viajes ha quedado intacta' as resultado;
