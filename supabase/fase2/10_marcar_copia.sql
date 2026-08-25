-- ============================================================
-- Marca esta base como COPIA DE VALIDACIÓN.
--
-- Se aplica UNA VEZ, justo después de restaurar el volcado y ANTES de
-- cualquier otra cosa. La guarda `guarda-no-produccion.sh` exige que esta
-- marca exista Y que su sello sea exactamente el esperado: una tabla con ese
-- nombre pero con otro contenido NO vale.
--
-- Producción NO tiene esta tabla y no debe tenerla nunca. Ese es el punto:
-- la guarda no depende de que alguien lea bien una cadena de conexión.
-- ============================================================
\set ON_ERROR_STOP on

create table if not exists public.copia_de_validacion (
    sello      text not null,
    marcada_en timestamptz not null default now(),
    nota       text not null
);

-- Por si la tabla venía de una versión anterior sin sello.
alter table public.copia_de_validacion add column if not exists sello text;

insert into public.copia_de_validacion (sello, nota)
values ('COPIA-DE-VALIDACION-FASE-2',
        'Copia de validación de la fase 2. NO es producción. '
        'Si ves esta tabla en el proyecto real, bórrala y avisa.');

do $$
declare
    validas integer;
begin
    select count(*) into validas from public.copia_de_validacion
     where sello = 'COPIA-DE-VALIDACION-FASE-2';

    if validas = 0 then
        raise exception 'No se ha podido poner el sello de copia de validación';
    end if;

    raise notice 'Base marcada como copia de validación (% sello(s) válido(s))', validas;
end $$;
