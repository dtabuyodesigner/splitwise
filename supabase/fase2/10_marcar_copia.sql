-- ============================================================
-- Marca esta base como COPIA DE VALIDACIÓN.
--
-- Se aplica UNA VEZ, justo después de restaurar el volcado y ANTES de
-- cualquier otra cosa. La guarda `guarda-no-produccion.sh` exige que esta
-- marca exista: sin ella no ejecuta nada.
--
-- Producción NO tiene esta tabla y no debe tenerla nunca. Ese es el punto:
-- la guarda no depende de que alguien lea bien una cadena de conexión.
-- ============================================================
\set ON_ERROR_STOP on

create table if not exists public.copia_de_validacion (
    marcada_en   timestamptz not null default now(),
    nota         text not null
);

insert into public.copia_de_validacion (nota)
values ('Copia de validación de la fase 2. NO es producción. '
        'Si ves esta tabla en el proyecto real, bórrala y avisa.');

do $$
begin
    raise notice 'Base marcada como copia de validación (% filas)',
        (select count(*) from public.copia_de_validacion);
end $$;
