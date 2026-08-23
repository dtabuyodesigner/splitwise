-- ============================================================
-- Un trigger que ocupa el nombre `on_auth_user_created` sin crear perfiles
-- debe ABORTAR la migración, no solo avisar.
--
-- Se ejecuta con `--single-transaction` desde CI y se espera que FALLE. Este
-- archivo es la parte que comprueba, después, que el trigger ajeno sigue
-- intacto. Solo CI, sobre la base desechable.
-- ============================================================
\set ON_ERROR_STOP on

do $$
declare
    sigue_el_impostor integer;
    de_perfiles       integer;
begin
    select count(*) into sigue_el_impostor
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal
      and t.tgname = 'on_auth_user_created'
      and p.proname = 'impostor_de_alta';

    select count(*) into de_perfiles
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace fn on fn.oid = p.pronamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal
      and fn.nspname = 'public' and p.proname = 'handle_new_user' and p.pronargs = 0;

    if sigue_el_impostor <> 1 then
        raise exception
            'La migración ha tocado el trigger ajeno: quedan % con ese nombre y esa función',
            sigue_el_impostor;
    end if;

    if de_perfiles <> 0 then
        raise exception
            'La migración ha creado un trigger de perfiles pese al conflicto de nombre';
    end if;

    raise notice
        '[NO] ok — el trigger ajeno que ocupaba el nombre sigue intacto y no se ha creado ninguno encima';
end $$;

select 'Nombre ocupado: la migración aborta y no pisa nada' as resultado;
