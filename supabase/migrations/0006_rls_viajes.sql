-- ============================================================
-- 0006 · Cerrar la aplicación de VIAJES
--
-- Las tres tablas de viajes tenían doce políticas `using (true)` para el rol
-- `authenticated`: cualquier cuenta que se registrara —y el registro está
-- abierto— podía leer, escribir y borrar los viajes, el diario y las fotos.
--
-- Por qué hace falta una tabla de acceso explícita, y no basta con los datos
-- que ya hay:
--
--   · `viajes.autor` y `viaje_fotos.autor` son texto libre con un correo, no
--     una referencia a `auth.users`. Y TODAS las filas llevan el mismo autor,
--     así que filtrar por autor dejaría a la segunda persona sin acceso.
--   · `viaje_diario` no tiene columna de autor: se identifica por `viaje`.
--   · No hay ni una clave foránea hacia `auth.users` ni hacia `profiles`.
--
-- Es decir: los datos NO codifican quién puede entrar. Se crea por tanto una
-- pertenencia explícita, y se rellena con las dos personas que ya usaban la
-- aplicación, identificadas igual que en `0002b`: por el color de su perfil,
-- contrastado con la antigüedad. Sin UUID ni correos en el código.
--
-- Idempotente y pensada para aplicarse con --single-transaction.
-- ============================================================

-- ── 0 · ¿Está instalada la aplicación de viajes? ─────────────
-- Las tres tablas son de la OTRA aplicación: en una instalación limpia de
-- Splitwise no existen, y el CI aplica las migraciones sobre PostgreSQL
-- vacío. Sin esta guarda, 0006 aborta ahí.
--
-- Se usa `\if` de psql y no un `return` dentro de un DO: un `return` en un
-- bloque DO solo abandona ese bloque, y el resto del archivo seguiría.
select (to_regclass('public.viajes')       is not null
    and to_regclass('public.viaje_diario') is not null
    and to_regclass('public.viaje_fotos')  is not null) as hay_viajes \gset

\if :hay_viajes

-- ── 1 · Quién puede entrar en Viajes ─────────────────────────
create table if not exists public.viajes_acceso (
    user_id      uuid primary key references auth.users(id) on delete cascade,
    concedido_en timestamptz not null default now(),
    nota         text not null default ''
);

comment on table public.viajes_acceso is
    'Quién puede usar la aplicación de viajes. Tener perfil NO da acceso: '
    'hay que estar aquí. Las altas las hace una persona, no el registro.';

alter table public.viajes_acceso enable row level security;

-- ── 2 · La comprobación, en una función con dueño ────────────
-- SECURITY DEFINER para que la política no dependa de que quien pregunta
-- pueda ver su propia fila: un `exists` sobre una tabla con RLS significa
-- «existe Y puedo verla», y eso es fácil de romper sin darse cuenta.
create or replace function public.puede_viajes()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.viajes_acceso a
         where a.user_id = auth.uid()
    );
$$;

revoke all on function public.puede_viajes() from public;
grant execute on function public.puede_viajes() to authenticated;

comment on function public.puede_viajes() is
    'true si la sesión actual está en public.viajes_acceso.';

-- ── 3 · Retirar las políticas abiertas ───────────────────────
-- Se enumeran del catálogo, acotadas a EXACTAMENTE las tres tablas de viajes:
-- un nombre desconocido sobreviviría en silencio, y las políticas permissive
-- se combinan con OR, así que una sola superviviente reabriría la tabla.
do $retirar$
declare
    p record;
    retiradas integer := 0;
begin
    for p in
        select schemaname, tablename, policyname
          from pg_policies
         where schemaname = 'public'
           and tablename in ('viajes', 'viaje_diario', 'viaje_fotos')
    loop
        execute format('drop policy %I on %I.%I',
                       p.policyname, p.schemaname, p.tablename);
        raise notice 'Política abierta retirada: %.% → %',
                     p.schemaname, p.tablename, p.policyname;
        retiradas := retiradas + 1;
    end loop;
    raise notice '% política(s) retiradas de las tablas de viajes', retiradas;
end
$retirar$;

-- Las tablas de gastos NO se tocan aquí. Comprobación explícita.
do $intactas$
declare
    n integer;
begin
    select count(*) into n from pg_policies
     where schemaname = 'public'
       and tablename in ('profiles','groups','group_members','expenses','settlements');
    raise notice 'Políticas de Splitwise intactas: %', n;
end
$intactas$;

-- ── 4 · RLS en las tres tablas ───────────────────────────────
alter table public.viajes       enable row level security;
alter table public.viaje_diario enable row level security;
alter table public.viaje_fotos  enable row level security;

drop policy if exists viajes_leer      on public.viajes;
drop policy if exists viajes_crear     on public.viajes;
drop policy if exists viajes_modificar on public.viajes;
drop policy if exists viajes_borrar    on public.viajes;

create policy viajes_leer on public.viajes
    for select to authenticated using (public.puede_viajes());
create policy viajes_crear on public.viajes
    for insert to authenticated with check (public.puede_viajes());
create policy viajes_modificar on public.viajes
    for update to authenticated
    using (public.puede_viajes()) with check (public.puede_viajes());
create policy viajes_borrar on public.viajes
    for delete to authenticated using (public.puede_viajes());

drop policy if exists diario_leer      on public.viaje_diario;
drop policy if exists diario_crear     on public.viaje_diario;
drop policy if exists diario_modificar on public.viaje_diario;
drop policy if exists diario_borrar    on public.viaje_diario;

create policy diario_leer on public.viaje_diario
    for select to authenticated using (public.puede_viajes());
create policy diario_crear on public.viaje_diario
    for insert to authenticated with check (public.puede_viajes());
create policy diario_modificar on public.viaje_diario
    for update to authenticated
    using (public.puede_viajes()) with check (public.puede_viajes());
create policy diario_borrar on public.viaje_diario
    for delete to authenticated using (public.puede_viajes());

drop policy if exists fotos_leer      on public.viaje_fotos;
drop policy if exists fotos_crear     on public.viaje_fotos;
drop policy if exists fotos_modificar on public.viaje_fotos;
drop policy if exists fotos_borrar    on public.viaje_fotos;

create policy fotos_leer on public.viaje_fotos
    for select to authenticated using (public.puede_viajes());
create policy fotos_crear on public.viaje_fotos
    for insert to authenticated with check (public.puede_viajes());
create policy fotos_modificar on public.viaje_fotos
    for update to authenticated
    using (public.puede_viajes()) with check (public.puede_viajes());
create policy fotos_borrar on public.viaje_fotos
    for delete to authenticated using (public.puede_viajes());

-- ── 5 · La tabla de acceso: se ve la fila propia y nada más ──
-- Sin política de INSERT, UPDATE ni DELETE: nadie se concede acceso a sí
-- mismo desde el cliente. Las altas las hace una persona con service_role o
-- desde el panel. Y al ver solo la fila propia, la tabla no sirve para
-- enumerar usuarios.
-- Solo SELECT: la política de abajo lo acota a la fila propia. Sin INSERT,
-- UPDATE ni DELETE, para que nadie pueda concederse acceso desde el cliente.
grant select on public.viajes_acceso to authenticated;
revoke insert, update, delete on public.viajes_acceso from authenticated;
revoke all on public.viajes_acceso from anon;

drop policy if exists viajes_acceso_ver_el_mio on public.viajes_acceso;
create policy viajes_acceso_ver_el_mio on public.viajes_acceso
    for select to authenticated using (user_id = auth.uid());

-- ── 6 · Backfill: las dos personas que ya la usaban ──────────
-- Mismo método que `0002b`: por color de perfil, contrastado con la
-- antigüedad. Si algo no encaja, aborta y no concede acceso a nadie.
do $backfill$
declare
    perfiles      integer;
    ya_concedidos integer;
    dani          uuid;
    pilar         uuid;
    primera       uuid;
    insertadas    integer;
begin
    select count(*) into ya_concedidos from public.viajes_acceso;
    if ya_concedidos > 0 then
        raise notice 'viajes_acceso ya tiene % fila(s): no se rellena', ya_concedidos;
        return;
    end if;

    select count(*) into perfiles from public.profiles;
    if perfiles = 0 then
        raise notice 'Instalación limpia: no hay perfiles, no se concede acceso a nadie';
        return;
    end if;

    if perfiles <> 2 then
        raise exception
            'Se esperaban exactamente 2 perfiles para el backfill de viajes, hay %', perfiles
            using hint = 'Decide a mano quién debe entrar en viajes e inserta en public.viajes_acceso.',
                  errcode = 'data_exception';
    end if;

    select id into dani  from public.profiles where color = 'laurel';
    select id into pilar from public.profiles where color = 'buganvilla';

    if dani is null or pilar is null or dani = pilar then
        raise exception 'No se han podido resolver los dos perfiles por color (laurel / buganvilla)'
            using hint = 'Sin esa correspondencia no se concede acceso a nadie.',
                  errcode = 'data_exception';
    end if;

    -- Segunda vía independiente: el perfil más antiguo debe ser el de laurel.
    select id into primera from public.profiles order by created_at, id limit 1;
    if primera <> dani then
        raise exception 'El color y la antigüedad de los perfiles no concuerdan'
            using hint = 'Comprueba a mano quién es quién antes de conceder acceso.',
                  errcode = 'data_exception';
    end if;

    insert into public.viajes_acceso (user_id, nota)
    values (dani,  'Backfill 0006: ya usaba la aplicación de viajes'),
           (pilar, 'Backfill 0006: ya usaba la aplicación de viajes')
    on conflict (user_id) do nothing;

    get diagnostics insertadas = row_count;
    raise notice 'Backfill de viajes: % acceso(s) concedido(s)', insertadas;

    if (select count(*) from public.viajes_acceso) <> 2 then
        raise exception 'El backfill de viajes no ha dejado exactamente 2 accesos';
    end if;
end
$backfill$;

-- ── 7 · Comprobación final ───────────────────────────────────
do $final$
declare
    abiertas integer;
    total    integer;
begin
    select count(*) into abiertas from pg_policies
     where schemaname = 'public'
       and tablename in ('viajes','viaje_diario','viaje_fotos')
       and (qual = 'true' or with_check = 'true');
    if abiertas > 0 then
        raise exception 'Quedan % política(s) abiertas en viajes', abiertas;
    end if;

    select count(*) into total from pg_policies
     where schemaname = 'public'
       and tablename in ('viajes','viaje_diario','viaje_fotos');
    if total <> 12 then
        raise exception 'Se esperaban 12 políticas en viajes, hay %', total;
    end if;

    if not exists (select 1 from pg_tables where schemaname='public'
                    and tablename='viajes_acceso' and rowsecurity) then
        raise exception 'viajes_acceso no tiene RLS activa';
    end if;

    raise notice 'Viajes cerrado: 12 políticas, ninguna abierta, acceso por pertenencia explícita';
end
$final$;

\else
\echo '0006: la aplicación de viajes no está instalada en esta base. No se hace nada.'
\endif
