-- ============================================================
-- Anonimización de la COPIA · OPCIONAL
--
--     psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/fase2/40_anonimizar.sql
--
-- Se aplica SOLO a la copia, y solo si el volcado va a vivir en un portátil
-- o va a compartirse. NUNCA contra producción: por eso empieza exigiendo la
-- marca de copia.
--
-- QUÉ BORRA          correos, metadatos de auth, nombres visibles,
--                    conceptos de gastos y notas de liquidaciones
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
    if to_regclass('public.copia_de_validacion') is null then
        raise exception
            'Esta base no lleva la marca de copia de validación: NO se anonimiza nada'
            using hint = 'Aplica antes supabase/fase2/10_marcar_copia.sql, y solo sobre la COPIA.';
    end if;
end $$;

update auth.users
   set email = 'usuario-' || left(md5(id::text), 8) || '@ejemplo.invalido',
       raw_user_meta_data = jsonb_build_object(
           'display_name', 'Persona ' || left(md5(id::text), 4));

update public.profiles
   set display_name = 'Persona ' || left(md5(id::text), 4);

update public.expenses
   set description = 'gasto ' || left(md5(id::text), 6);

update public.settlements
   set note = case when note is null then null else 'nota ' || left(md5(id::text), 6) end;

do $$
declare
    con_correo_real integer;
begin
    select count(*) into con_correo_real from auth.users
     where email not like '%@ejemplo.invalido';

    if con_correo_real > 0 then
        raise exception 'Han quedado % correos sin anonimizar', con_correo_real;
    end if;

    raise notice 'Copia anonimizada: correos, nombres, conceptos y notas sustituidos. '
                 'Se conservan UUID, client_id, colores, nombres de grupo, fechas e importes.';
end $$;
