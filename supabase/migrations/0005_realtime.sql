-- ============================================================
-- 0005 · Publicación de Realtime
--
-- NO APLICADA.
--
-- Supabase Realtime respeta RLS SOLO si la publicación está configurada y
-- el cliente está autenticado. Con 0004 aplicada, un cliente deja de
-- recibir eventos de grupos de los que no es miembro.
--
-- REPLICA IDENTITY FULL es necesario para que los eventos de UPDATE y
-- DELETE lleven las columnas por las que se filtra (`group_id`): sin él,
-- el filtro `group_id=eq.…` del cliente no puede aplicarse a un DELETE.
-- Tiene un coste en el WAL; con el volumen de esta app es despreciable.
-- ============================================================

alter table public.expenses    replica identity full;
alter table public.settlements replica identity full;

do $$
begin
    if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        create publication supabase_realtime;
    end if;
end $$;

-- `add table` falla si la tabla ya está en la publicación; se comprueba antes.
do $$
declare
    t text;
begin
    foreach t in array array['expenses', 'settlements', 'groups', 'profiles', 'group_members']
    loop
        if not exists (
            select 1 from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
        ) then
            execute format('alter publication supabase_realtime add table public.%I', t);
        end if;
    end loop;
end $$;
