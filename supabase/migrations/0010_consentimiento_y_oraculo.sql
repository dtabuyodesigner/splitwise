-- ============================================================
-- 0010 · Consentimiento para entrar en un grupo, y fin del oráculo
--
-- Cierra los dos hallazgos de la auditoría previa a las invitaciones:
--
--   H1 · Cualquier miembro podía meter a CUALQUIER persona en su grupo.
--   H2 · `es_miembro()` y `es_owner()` respondían sobre terceros en grupos
--        que quien preguntaba no puede ni ver.
--
-- No toca datos. No toca `expenses`, `settlements` ni `balance_transfers`.
-- Ningún grupo existente cambia de miembros ni de saldo.
--
-- Es idempotente: se puede reaplicar sin efecto.
-- ============================================================

-- ============================================================
-- H1 · Nadie entra en un grupo sin haberlo decidido
--
-- La regla pasa a ser: **una persona solo se apunta a sí misma**. Meter a
-- otra es competencia exclusiva de `aceptar_invitacion()` (0011), que es
-- SECURITY DEFINER y por tanto no pasa por estas políticas.
--
-- Había DOS caminos abiertos, y los dos se comprobaron ejecutándolos:
--
--   1. INSERT. `miembros_invitar` exigía solo `es_miembro(group_id)`, sin
--      mirar el `user_id` insertado. Un POST a /rest/v1/group_members metía
--      a quien fuera en tu grupo: la víctima veía de pronto un grupo al que
--      nunca se apuntó, y su perfil quedaba visible para desconocidos.
--
--   2. UPDATE. `miembros_cambiar_rol` acota QUIÉN puede actualizar (el
--      propietario) pero no QUÉ columnas. Un `update group_members set
--      user_id = '<víctima>'` sustituía a un miembro por cualquier persona.
--      Esta era la puerta que no se vio en la auditoría.
-- ============================================================

-- ── H1.1 · INSERT: solo uno mismo, y solo en el grupo que ha creado ──
--
-- Se conserva EXACTAMENTE la rama que 0004 ya tenía como red de seguridad y
-- se retira la otra. La rama que queda es segura porque se apoya en
-- `groups.created_by`, que solo satisface quien creó el grupo.
--
-- Sigue siendo necesaria: `js/supabase-data.js` → `crearGrupo()` inserta la
-- membresía del creador después del `insert` del grupo, por si el trigger
-- `apuntar_creador_como_miembro` no llegara a ejecutarse. Sin ella, crear un
-- grupo dejaría de funcionar en ese caso degradado.
drop policy if exists miembros_invitar on public.group_members;
drop policy if exists miembros_apuntarme_a_mi_grupo on public.group_members;
create policy miembros_apuntarme_a_mi_grupo on public.group_members
    for insert to authenticated
    with check (
        user_id = auth.uid()
        and exists (
            select 1 from public.groups g
            where g.id = group_members.group_id
              and g.created_by = auth.uid()
        )
    );

-- ── H1.2 · UPDATE: solo se puede tocar la columna `role` ──
--
-- RLS no sirve para esto. En una política de UPDATE, `using` ve la fila
-- ANTIGUA y `with check` la NUEVA, pero ninguna de las dos expresiones puede
-- ver las dos a la vez, así que no hay forma de escribir "y además `user_id`
-- no ha cambiado". El privilegio por columnas de PostgreSQL sí lo expresa, y
-- lo hace antes de que RLS entre en juego.
revoke update on public.group_members from authenticated;
grant update (role) on public.group_members to authenticated;

-- `miembros_cambiar_rol` (0004) se conserva tal cual: sigue decidiendo QUIÉN
-- puede actualizar —solo el propietario—. Lo que añade este grant es QUÉ
-- puede tocar. Las dos cosas se combinan: hace falta pasar las dos.

-- ============================================================
-- H2 · Las funciones de pertenencia dejan de ser un oráculo
--
-- `es_miembro(grupo, persona)` y `es_owner(...)` están concedidas a
-- `authenticated` porque las políticas RLS las invocan, y una política se
-- evalúa con el rol de quien consulta. Pero eso las convierte también en RPC
-- llamables a mano por PostgREST, y respondían la verdad sobre CUALQUIER par
-- (grupo, persona). Comprobado:
--
--     es_miembro('<grupo ajeno>', '<persona ajena>')  →  t
--     select * from groups                            →  0 filas
--
-- Con dos UUID que no deberías tener, confirmabas que X está en el grupo G.
-- Los UUID no se adivinan y `profiles_leer` impide enumerarlos, por eso era
-- de gravedad baja; pero es información que no hay ninguna razón para dar.
--
-- El arreglo: solo se responde sobre uno mismo, o sobre terceros cuando
-- quien pregunta YA pertenece a ese grupo —y entonces la respuesta no le
-- dice nada que `miembros_leer` no le enseñe ya—. En cualquier otro caso se
-- devuelve `false`.
--
-- POR QUÉ `false` Y NO UNA EXCEPCIÓN: estas funciones viven dentro de
-- políticas RLS. Una excepción abortaría la consulta del usuario legítimo en
-- vez de filtrar una fila. `false` es además el valor que la política habría
-- dado de todos modos —quien no es miembro del grupo ya tiene su primer
-- conjunto en `false`—, así que **ninguna política cambia de resultado**.
--
-- POR QUÉ NO HAY RECURSIÓN: siguen siendo SECURITY DEFINER, así que sus
-- consultas internas no pasan por RLS. La consulta añadida —"¿es miembro
-- quien pregunta?"— tampoco. Es la misma razón por la que 0002 las hizo
-- DEFINER, y no cambia.
--
-- COSTE: el `case` cortocircuita. Cuando se pregunta por uno mismo —que es
-- lo que hacen TODAS las llamadas de un solo argumento— se hace exactamente
-- la misma búsqueda que antes, una sola, por la clave primaria.
-- ============================================================
create or replace function public.es_miembro(p_group_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select case
        when p_group_id is null or p_user_id is null then false
        when p_user_id = auth.uid()
             or exists (select 1 from public.group_members
                         where group_id = p_group_id and user_id = auth.uid())
        then exists (select 1 from public.group_members
                      where group_id = p_group_id and user_id = p_user_id)
        else false
    end;
$$;

create or replace function public.es_owner(p_group_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select case
        when p_group_id is null or p_user_id is null then false
        when p_user_id = auth.uid()
             or exists (select 1 from public.group_members
                         where group_id = p_group_id and user_id = auth.uid())
        then exists (select 1 from public.group_members
                      where group_id = p_group_id
                        and user_id = p_user_id and role = 'owner')
        else false
    end;
$$;

-- `create or replace` conserva la ACL, pero la regla de SECURITY.md es que
-- toda función lleve sus tres líneas escritas. Se repiten para que no
-- dependan de lo que hubiera antes.
revoke all on function public.es_miembro(uuid, uuid) from public, anon;
revoke all on function public.es_owner(uuid, uuid)   from public, anon;
grant execute on function public.es_miembro(uuid, uuid) to authenticated;
grant execute on function public.es_owner(uuid, uuid)   to authenticated;

-- ------------------------------------------------------------
-- Comprobación inmediata, dentro de la propia migración
-- ------------------------------------------------------------
do $comprobar$
declare
    n integer;
begin
    select count(*) into n from pg_policies
     where schemaname = 'public' and tablename = 'group_members'
       and cmd = 'INSERT' and policyname = 'miembros_apuntarme_a_mi_grupo';
    if n <> 1 then
        raise exception '0010: no ha quedado la política de alta propia';
    end if;

    if exists (select 1 from pg_policies
                where schemaname = 'public' and tablename = 'group_members'
                  and policyname = 'miembros_invitar') then
        raise exception '0010: la política permisiva miembros_invitar sigue viva';
    end if;

    -- El privilegio de UPDATE tiene que ser de columna, no de tabla.
    if has_table_privilege('authenticated', 'public.group_members', 'update') then
        raise exception '0010: authenticated conserva UPDATE sobre toda la tabla';
    end if;
    if not has_column_privilege('authenticated', 'public.group_members', 'role', 'update') then
        raise exception '0010: authenticated ha perdido el UPDATE de role';
    end if;
    if has_column_privilege('authenticated', 'public.group_members', 'user_id', 'update') then
        raise exception '0010: authenticated todavía puede reescribir user_id';
    end if;

    raise notice 'H1 cerrado: solo uno mismo entra, y solo se puede actualizar «role».';
    raise notice 'H2 cerrado: es_miembro/es_owner solo responden sobre uno mismo o dentro del grupo propio.';
end
$comprobar$;
