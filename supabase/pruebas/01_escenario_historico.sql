-- ============================================================
-- Escenario de ACTUALIZACIÓN: reproduce el estado real de producción
-- ANTES de aplicar las migraciones de esta fase.
--
-- Se usa SOLO en CI, sobre un PostgreSQL vacío y desechable, para probar la
-- migración en las condiciones de verdad y no sobre una base limpia. Nunca
-- debe ejecutarse contra una base real.
--
-- Reproduce, según el inventario de solo lectura del proyecto:
--   · las cuatro tablas de gastos, sin `group_members`;
--   · RLS YA ACTIVA, con las políticas históricas y sus nombres reales,
--     todas PERMISSIVE y con using/with check a `true`;
--   · el trigger de alta que ya existe: on_auth_user_created → handle_new_user();
--   · la aplicación de VIAJES que comparte esta base de datos, que las
--     migraciones no deben tocar;
--   · datos con la misma forma que los reales (2 personas, 3 grupos, uno de
--     ellos sin ningún gasto).
-- ============================================================

-- ------------------------------------------------------------
--  Tablas de gastos, tal y como están hoy (sin group_members)
-- ------------------------------------------------------------
-- Igual que en producción, según el inventario: display_name NOT NULL sin
-- default, color NOT NULL con 'laurel' por defecto.
create table public.profiles (
    id           uuid primary key references auth.users(id) on delete cascade,
    display_name text not null,
    color        text not null default 'laurel',
    created_at   timestamptz not null default now()
);

create table public.groups (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    created_at timestamptz not null default now()
);

create table public.expenses (
    id          uuid primary key default gen_random_uuid(),
    group_id    uuid not null,
    paid_by     uuid not null,
    amount      numeric(12,2) not null,
    description text,
    category    text,
    payer_share numeric(5,4) not null default 0.5,
    spent_on    date not null default current_date,
    client_id   text,
    created_at  timestamptz not null default now()
);

create table public.settlements (
    id         uuid primary key default gen_random_uuid(),
    group_id   uuid not null,
    from_user  uuid not null,
    to_user    uuid not null,
    amount     numeric(12,2) not null,
    note       text,
    settled_on date not null default current_date,
    client_id  text,
    created_at timestamptz not null default now()
);

grant select, insert, update, delete
    on public.profiles, public.groups, public.expenses, public.settlements
    to authenticated;

-- ------------------------------------------------------------
--  El trigger de alta que YA EXISTE en producción
-- ------------------------------------------------------------
-- Reproduce el comportamiento REAL inspeccionado en producción:
-- display_name ← display_name, full_name, name o la parte anterior a la @
-- color        ← color del metadata, o laurel para el primero y buganvilla
--                para los siguientes. ON CONFLICT (id) DO NOTHING.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, display_name, color)
    values (
        new.id,
        coalesce(
            nullif(new.raw_user_meta_data ->> 'display_name', ''),
            nullif(new.raw_user_meta_data ->> 'full_name', ''),
            nullif(new.raw_user_meta_data ->> 'name', ''),
            nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
            'Sin nombre'
        ),
        coalesce(
            nullif(new.raw_user_meta_data ->> 'color', ''),
            case when (select count(*) from public.profiles) = 0
                 then 'laurel' else 'buganvilla' end
        )
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
--  RLS YA ACTIVA, con las políticas históricas permisivas
--
--  Este es el corazón del escenario: todas son PERMISSIVE y abren la tabla
--  entera. Como PostgreSQL combina las permissive con OR, si una sola
--  sobrevive a la migración, las políticas nuevas no cierran nada.
-- ------------------------------------------------------------
alter table public.profiles    enable row level security;
alter table public.groups      enable row level security;
alter table public.expenses    enable row level security;
alter table public.settlements enable row level security;

create policy "gastos visibles para la pareja" on public.expenses
    for select to authenticated using (true);
create policy "cualquiera de los dos añade gastos" on public.expenses
    for insert to authenticated with check (true);
create policy "cualquiera de los dos corrige gastos" on public.expenses
    for update to authenticated using (true) with check (true);
create policy "cualquiera de los dos borra gastos" on public.expenses
    for delete to authenticated using (true);

create policy "grupos visibles para la pareja" on public.groups
    for select to authenticated using (true);
create policy "cualquiera de los dos crea grupos" on public.groups
    for insert to authenticated with check (true);
create policy "cualquiera de los dos edita grupos" on public.groups
    for update to authenticated using (true) with check (true);
create policy "cualquiera de los dos borra grupos" on public.groups
    for delete to authenticated using (true);

create policy "perfiles visibles para la pareja" on public.profiles
    for select to authenticated using (true);
create policy "cada uno edita su perfil" on public.profiles
    for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "liquidaciones visibles para la pareja" on public.settlements
    for select to authenticated using (true);
create policy "cualquiera de los dos liquida" on public.settlements
    for insert to authenticated with check (true);
create policy "cualquiera de los dos borra liquidaciones" on public.settlements
    for delete to authenticated using (true);

-- ------------------------------------------------------------
--  LA APLICACIÓN DE VIAJES, que comparte esta base de datos
--
--  Las migraciones de gastos NO deben tocar nada de esto. La prueba de
--  frontera (96/97) compara su estado antes y después.
-- ------------------------------------------------------------
create table public.viajes (
    id          uuid primary key default gen_random_uuid(),
    titulo      text not null,
    inicio      date,
    fin         date,
    creado_por  uuid references public.profiles(id) on delete set null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table public.viaje_diario (
    id        uuid primary key default gen_random_uuid(),
    viaje_id  uuid not null references public.viajes(id) on delete cascade,
    dia       date not null,
    texto     text,
    created_at timestamptz not null default now()
);

create table public.viaje_fotos (
    id        uuid primary key default gen_random_uuid(),
    viaje_id  uuid not null references public.viajes(id) on delete cascade,
    url       text not null,
    created_at timestamptz not null default now()
);

create index idx_viaje_diario_viaje on public.viaje_diario(viaje_id);
create index idx_viaje_fotos_viaje  on public.viaje_fotos(viaje_id);

create or replace function public.viajes_tocar()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create trigger viajes_tocar_trg
    before update on public.viajes
    for each row execute function public.viajes_tocar();

alter table public.viajes       enable row level security;
alter table public.viaje_diario enable row level security;
alter table public.viaje_fotos  enable row level security;

grant select, insert, update, delete
    on public.viajes, public.viaje_diario, public.viaje_fotos
    to authenticated;

create policy "viajes visibles para la pareja" on public.viajes
    for select to authenticated using (true);
create policy "cualquiera de los dos crea viajes" on public.viajes
    for insert to authenticated with check (true);
create policy "cualquiera de los dos edita viajes" on public.viajes
    for update to authenticated using (true) with check (true);
create policy "diario visible para la pareja" on public.viaje_diario
    for select to authenticated using (true);
create policy "cualquiera de los dos escribe el diario" on public.viaje_diario
    for insert to authenticated with check (true);
create policy "fotos visibles para la pareja" on public.viaje_fotos
    for select to authenticated using (true);
create policy "cualquiera de los dos sube fotos" on public.viaje_fotos
    for insert to authenticated with check (true);

do $$
begin
    if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        create publication supabase_realtime;
    end if;
end $$;

alter publication supabase_realtime add table public.viajes;
alter publication supabase_realtime add table public.viaje_diario;

-- ------------------------------------------------------------
--  Datos con la misma forma que los reales
--  2 cuentas · 3 grupos, uno de ellos SIN ningún gasto · 1 liquidación
-- ------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
    ('11111111-1111-1111-1111-111111111111', 'p1@ejemplo.test', '{"display_name":"Perfil Uno"}'),
    ('22222222-2222-2222-2222-222222222222', 'p2@ejemplo.test', '{"display_name":"Perfil Dos"}');

-- Los tres grupos históricos reales. "Casa" está VACÍO a propósito: es el
-- que no tenía ninguna pista de pertenencia en el inventario.
insert into public.groups (id, name) values
    ('aaaaaaaa-0000-0000-0000-0000000000c0', 'Casa'),
    ('aaaaaaaa-0000-0000-0000-0000000000f0', 'Slovenia'),
    ('aaaaaaaa-0000-0000-0000-0000000000b0', 'Bierzo & Asturias');

-- 51 gastos repartidos entre las dos personas, como el grupo grande real.
insert into public.expenses (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
select 'aaaaaaaa-0000-0000-0000-0000000000f0'::uuid,
       (case when i % 2 = 0 then '11111111-1111-1111-1111-111111111111'
                            else '22222222-2222-2222-2222-222222222222' end)::uuid,
       10 + i, 'gasto ' || i, 'otros', 0.5, current_date, 'hist-' || i
from generate_series(1, 51) as i;

insert into public.expenses (group_id, paid_by, amount, description, category, payer_share, spent_on, client_id)
values ('aaaaaaaa-0000-0000-0000-0000000000b0', '11111111-1111-1111-1111-111111111111',
        20, 'gasto a', 'otros', 0.5, current_date, 'hist-b1'),
       ('aaaaaaaa-0000-0000-0000-0000000000b0', '22222222-2222-2222-2222-222222222222',
        30, 'gasto b', 'otros', 0.5, current_date, 'hist-b2');

insert into public.settlements (group_id, from_user, to_user, amount, settled_on, client_id)
values ('aaaaaaaa-0000-0000-0000-0000000000f0',
        '22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111',
        100, current_date, 'hist-liq-1');

insert into public.viajes (id, titulo, creado_por) values
    ('bbbbbbbb-0000-0000-0000-000000000001', 'Un viaje',
     '11111111-1111-1111-1111-111111111111');
insert into public.viaje_diario (viaje_id, dia, texto)
values ('bbbbbbbb-0000-0000-0000-000000000001', current_date, 'una nota');
insert into public.viaje_fotos (viaje_id, url)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'https://ejemplo.test/f.jpg');
