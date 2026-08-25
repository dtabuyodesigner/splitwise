-- ============================================================
-- Alta de un usuario nuevo tras migrar
--
-- Comprueba que existe UN ÚNICO mecanismo efectivo de creación de perfiles:
-- ni cero (el usuario nuevo no aparecería nunca en la app) ni dos compitiendo
-- (podrían duplicar filas o pisarse display_name y color).
--
-- Todo dentro de una transacción que termina en ROLLBACK.
-- ============================================================
\set ON_ERROR_STOP on

begin;

-- 1 · Un solo trigger de alta sobre auth.users
do $$
declare
    cuantos integer;
    cuales  text;
begin
    -- Se cuentan los triggers que ejecutan public.handle_new_user(), no los
    -- triggers de auth.users en general: uno ajeno sería de otra aplicación.
    select count(*), string_agg(t.tgname, ', ')
      into cuantos, cuales
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace fn on fn.oid = p.pronamespace
    where n.nspname = 'auth' and rel.relname = 'users' and not t.tgisinternal
      and fn.nspname = 'public' and p.proname = 'handle_new_user' and p.pronargs = 0;

    if cuantos <> 1 then
        raise exception
            'Debe haber EXACTAMENTE un mecanismo de alta de perfiles y hay %: %',
            cuantos, coalesce(cuales, '(ninguno)');
    end if;

    raise notice '[U01] ok — un único mecanismo de alta: %', cuales;
end $$;

-- 2 · Dar de alta a alguien crea exactamente un perfil
do $$
declare
    antes    integer;
    despues  integer;
    suyos    integer;
    su_nombre text;
    su_color  text;
begin
    select count(*) into antes from public.profiles;

    insert into auth.users (id, email, raw_user_meta_data)
    values ('77777777-7777-7777-7777-777777777777', 'nuevo@ejemplo.test',
            '{"display_name":"Alguien Nuevo"}');

    select count(*) into despues from public.profiles;
    select count(*) into suyos from public.profiles
     where id = '77777777-7777-7777-7777-777777777777';

    if despues <> antes + 1 then
        raise exception
            'El alta debería crear exactamente 1 perfil: había %, hay %', antes, despues;
    end if;
    if suyos <> 1 then
        raise exception 'El usuario nuevo tiene % perfiles', suyos;
    end if;

    select display_name, color into su_nombre, su_color
    from public.profiles where id = '77777777-7777-7777-7777-777777777777';

    if su_nombre is null or su_nombre = '' then
        raise exception 'El perfil nuevo se ha quedado sin display_name';
    end if;
    if su_color is null or su_color = '' then
        raise exception 'El perfil nuevo se ha quedado sin color';
    end if;

    raise notice '[U02] ok — el alta crea exactamente un perfil, con nombre "%" y color "%"',
        su_nombre, su_color;
end $$;

-- 3 · Y esa cuenta nueva no ve absolutamente nada: el alta pública está
--     ACTIVADA en Supabase, así que cualquiera puede registrarse. Con las
--     políticas nuevas, registrarse no da acceso a ningún dato ajeno.
set local role authenticated;
set local request.jwt.claims = '{"sub":"77777777-7777-7777-7777-777777777777"}';

do $$
declare
    g integer; e integer; s integer; m integer; p integer;
begin
    select count(*) into g from public.groups;
    select count(*) into e from public.expenses;
    select count(*) into s from public.settlements;
    select count(*) into m from public.group_members;
    select count(*) into p from public.profiles;

    if g <> 0 or e <> 0 or s <> 0 or m <> 0 then
        raise exception
            'FUGA: una cuenta recién registrada ve % grupos, % gastos, % liquidaciones, % membresías',
            g, e, s, m;
    end if;
    if p <> 1 then
        raise exception 'FUGA: una cuenta recién registrada ve % perfiles', p;
    end if;

    raise notice '[U03] ok — registrarse NO da acceso a ningún dato ajeno';
end $$;

reset role;
rollback;

select 'Alta de usuario: un solo mecanismo, y sin acceso a datos ajenos' as resultado;
