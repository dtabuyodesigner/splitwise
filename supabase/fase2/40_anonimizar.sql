-- ============================================================
-- Anonimización de la COPIA · OPCIONAL
--
--     psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/fase2/40_anonimizar.sql
--
-- ⚠️  ES IRREVERSIBLE SOBRE ESTA COPIA. Sobrescribe los datos en el sitio y
--     no hay forma de recuperarlos desde aquí. Si luego hacen falta los datos
--     originales, hay que volver a restaurar el volcado:
--
--         dropdb copia_validacion && createdb copia_validacion
--         pg_restore --no-owner --no-privileges -d copia_validacion copia-produccion.dump
--
--     Por eso conviene anonimizar DESPUÉS de la fotografía previa y ANTES de
--     que la copia se quede en el disco más de una sesión.
--
-- Se aplica SOLO a la copia, NUNCA contra producción: empieza exigiendo el
-- sello de copia de validación.
--
-- QUÉ BORRA
--   · auth.users: correo, teléfono, metadatos, y —si existen en el volcado—
--     el hash de contraseña y todos los tokens de confirmación y recuperación
--   · profiles.display_name
--   · expenses.description  ·  settlements.note
--
-- QUÉ CONSERVA, y por qué hace falta para que la validación signifique algo:
--   · los UUID y las relaciones  → integridad referencial y claves foráneas
--   · `client_id`                → el índice único y la idempotencia
--   · `profiles.color`           → el backfill identifica a cada persona por color
--   · los NOMBRES DE LOS GRUPOS  → el backfill exige exactamente los tres
--   · fechas e importes          → las restricciones CHECK y los saldos
-- ============================================================
\set ON_ERROR_STOP on

do $$
begin
    if to_regclass('public.copia_de_validacion') is null
       or not exists (select 1 from public.copia_de_validacion
                       where sello = 'COPIA-DE-VALIDACION-FASE-2') then
        raise exception
            'Esta base no lleva el sello de copia de validación: NO se anonimiza nada'
            using hint = 'Aplica antes supabase/fase2/10_marcar_copia.sql, y solo sobre la COPIA.';
    end if;
end $$;

-- ── auth.users ──────────────────────────────────────────────
-- Las columnas se tocan una a una y solo si existen: el volcado real de
-- Supabase trae bastantes más que el sustituto que usa el CI, y algunas
-- guardan credenciales.
do $$
declare
    col  text;
    -- columna → expresión con la que se sustituye
    reemplazos constant text[][] := array[
        ['email',                 $r$'usuario-' || left(md5(id::text), 8) || '@ejemplo.invalido'$r$],
        ['phone',                 $r$null$r$],
        ['raw_user_meta_data',    $r$jsonb_build_object('display_name', 'Persona ' || left(md5(id::text), 4))$r$],
        ['raw_app_meta_data',     $r$'{}'::jsonb$r$],
        ['encrypted_password',    $r$'ANONIMIZADO-NO-VALIDO'$r$],
        ['confirmation_token',    $r$''$r$],
        ['recovery_token',        $r$''$r$],
        ['email_change',          $r$''$r$],
        ['email_change_token_new',$r$''$r$],
        ['email_change_token_current', $r$''$r$],
        ['phone_change',          $r$''$r$],
        ['phone_change_token',    $r$''$r$],
        ['reauthentication_token',$r$''$r$]
    ];
    i integer;
    tocadas text := '';
begin
    for i in 1 .. array_length(reemplazos, 1) loop
        col := reemplazos[i][1];

        if exists (
            select 1 from information_schema.columns
            where table_schema = 'auth' and table_name = 'users' and column_name = col
        ) then
            execute format('update auth.users set %I = %s', col, reemplazos[i][2]);
            tocadas := tocadas || col || ' ';
        end if;
    end loop;

    raise notice 'auth.users anonimizada. Columnas sustituidas: %', tocadas;
end $$;

-- ── Tablas de la aplicación ─────────────────────────────────
update public.profiles
   set display_name = 'Persona ' || left(md5(id::text), 4);

update public.expenses
   set description = 'gasto ' || left(md5(id::text), 6);

update public.settlements
   set note = case when note is null then null else 'nota ' || left(md5(id::text), 6) end;

-- ── Comprobación: no puede quedar nada sin anonimizar ───────
do $$
declare
    correos   integer;
    telefonos integer := 0;
begin
    select count(*) into correos from auth.users
     where email is not null and email not like '%@ejemplo.invalido';

    if correos > 0 then
        raise exception 'Han quedado % correos sin anonimizar', correos;
    end if;

    if exists (select 1 from information_schema.columns
               where table_schema = 'auth' and table_name = 'users' and column_name = 'phone') then
        execute 'select count(*) from auth.users where phone is not null' into telefonos;
        if telefonos > 0 then
            raise exception 'Han quedado % teléfonos sin anonimizar', telefonos;
        end if;
    end if;

    raise notice 'Copia anonimizada y comprobada. Se conservan UUID, client_id, '
                 'colores, nombres de grupo, fechas e importes.';
end $$;
