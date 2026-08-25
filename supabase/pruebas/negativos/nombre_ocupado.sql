-- Un trigger que ocupa EXACTAMENTE el nombre `on_auth_user_created` pero no
-- ejecuta public.handle_new_user(). La migración debe ABORTAR: si solo
-- avisara, el despliegue terminaría con apariencia de correcto y sin ningún
-- mecanismo que cree perfiles.
create or replace function public.impostor_de_alta()
returns trigger language plpgsql as $$
begin
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.impostor_de_alta();
