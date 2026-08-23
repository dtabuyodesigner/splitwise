-- Un trigger de OTRA aplicación sobre auth.users. No ejecuta
-- public.handle_new_user(), así que no debe impedir que 0001 instale el
-- mecanismo de perfiles: si lo impidiera, los usuarios nuevos no aparecerían.
create or replace function public.auditoria_ajena()
returns trigger language plpgsql as $$
begin
    return new;
end;
$$;

create trigger zz_auditoria_de_otra_app
    after insert on auth.users
    for each row execute function public.auditoria_ajena();
