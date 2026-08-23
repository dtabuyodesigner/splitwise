-- ============================================================
-- Un trigger AJENO sobre auth.users no debe impedir instalar el mecanismo
-- de perfiles.
--
-- Esta base la comparten varias aplicaciones. Si 0001 se limitara a mirar
-- "¿hay algún trigger en auth.users?", un trigger de auditoría de otra app
-- bloquearía la creación del de perfiles, y los usuarios nuevos no
-- aparecerían nunca en la aplicación de gastos.
--
-- Todo dentro de una transacción que termina en ROLLBACK: no deja rastro.
-- ============================================================
\set ON_ERROR_STOP on

begin;

\ir negativos/trigger_ajeno.sql
\ir ../migrations/0001_baseline_esquema.sql

do $$
declare
    de_perfiles integer;
    ajenos      integer;
    total       integer;
begin
    select count(*) into de_perfiles
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace fn on fn.oid = p.pronamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal
      and fn.nspname = 'public' and p.proname = 'handle_new_user' and p.pronargs = 0;

    select count(*) into ajenos
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal
      and t.tgname = 'zz_auditoria_de_otra_app';

    select count(*) into total
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal;

    if de_perfiles <> 1 then
        raise exception
            'Un trigger ajeno ha impedido instalar el mecanismo de perfiles: hay % (debería haber 1)',
            de_perfiles
            using hint = 'Los usuarios nuevos no aparecerían nunca en la aplicación.';
    end if;

    if ajenos <> 1 then
        raise exception 'El trigger de la otra aplicación ha desaparecido';
    end if;

    if total <> 2 then
        raise exception 'Se esperaban 2 triggers en auth.users (el ajeno y el de perfiles) y hay %', total;
    end if;

    raise notice
        '[TA] ok — un trigger ajeno no impide instalar el de perfiles, y no se toca: % triggers en total',
        total;
end $$;

rollback;

select 'Trigger ajeno: convivencia correcta' as resultado;
