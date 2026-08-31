-- ============================================================
-- Invitaciones y consentimiento · pruebas EJECUTANDO consultas reales
--
-- Cubre los dos hallazgos de la auditoría (H1 y H2) y los catorce escenarios
-- del sistema de invitaciones. Suplanta usuarios de verdad y ejecuta las RPC
-- de verdad: las comprobaciones de catálogo no habrían visto ni el bypass de
-- `not exists` de 0004 ni el `update user_id` que cerró 0010.
--
-- Todo dentro de una transacción que termina en ROLLBACK. Se puede ejecutar
-- contra cualquier base con las migraciones aplicadas sin dejar rastro.
--
-- La concurrencia (dos aceptaciones a la vez) NO se puede probar desde un
-- solo psql: va aparte, en `111_aceptaciones_concurrentes.sh`.
-- ============================================================
\set ON_ERROR_STOP on

begin;

create temporary table registro_inv (id text primary key, descripcion text);

-- Las aserciones se ejecutan suplantando a usuarios normales, así que los
-- roles de aplicación tienen que poder escribir en la tabla del registro.
-- Es una tabla TEMPORAL: no existe fuera de esta sesión ni deja rastro.
grant insert, select on registro_inv to authenticated, anon;

create or replace function pg_temp.af(p_id text, p_ok boolean, p_desc text)
returns void language plpgsql as $$
begin
    if p_ok is null or not p_ok then
        raise exception '[%] FALLA — %', p_id, p_desc using errcode = 'assert_failure';
    end if;
    insert into registro_inv values (p_id, p_desc);
    raise notice '[%] ok — %', p_id, p_desc;
end $$;

-- ------------------------------------------------------------
--  El mundo de la prueba: seis personas, tres grupos
--  (el mismo escenario de la auditoría)
--
--   · «Heredado»   Dani + Pilar        — el grupo que ya existía
--   · «Viaje»      Alba + Amigo1       — Alba invitará a Amigo2
--   · «Ajeno»      Amigo1 + Extraño    — Alba no debe verlo jamás
-- ------------------------------------------------------------
insert into auth.users (id, email) values
    ('d1111111-1111-1111-1111-111111111111', 'dani@prueba.test'),
    ('d2222222-2222-2222-2222-222222222222', 'pilar@prueba.test'),
    ('a0000000-0000-0000-0000-00000000000a', 'alba@prueba.test'),
    ('b0000000-0000-0000-0000-00000000000b', 'amigo1@prueba.test'),
    ('c0000000-0000-0000-0000-00000000000c', 'amigo2@prueba.test'),
    ('e0000000-0000-0000-0000-00000000000e', 'extrano@prueba.test');

update public.profiles set display_name = case id
    when 'd1111111-1111-1111-1111-111111111111' then 'Dani P'
    when 'd2222222-2222-2222-2222-222222222222' then 'Pilar P'
    when 'a0000000-0000-0000-0000-00000000000a' then 'Alba'
    when 'b0000000-0000-0000-0000-00000000000b' then 'Amigo1'
    when 'c0000000-0000-0000-0000-00000000000c' then 'Amigo2'
    else 'Extrano' end
 where id in ('d1111111-1111-1111-1111-111111111111','d2222222-2222-2222-2222-222222222222',
              'a0000000-0000-0000-0000-00000000000a','b0000000-0000-0000-0000-00000000000b',
              'c0000000-0000-0000-0000-00000000000c','e0000000-0000-0000-0000-00000000000e');

insert into public.groups (id, name, created_by) values
    ('91110000-0000-0000-0000-000000000001', 'Heredado', 'd1111111-1111-1111-1111-111111111111'),
    ('92220000-0000-0000-0000-000000000002', 'Viaje',    'a0000000-0000-0000-0000-00000000000a'),
    ('93330000-0000-0000-0000-000000000003', 'Ajeno',    'b0000000-0000-0000-0000-00000000000b');

insert into public.group_members (group_id, user_id, role) values
    ('91110000-0000-0000-0000-000000000001', 'd2222222-2222-2222-2222-222222222222', 'member'),
    ('92220000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-00000000000b', 'member'),
    ('93330000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-00000000000e', 'member');

insert into public.expenses (group_id, paid_by, amount, description, payer_share) values
    ('91110000-0000-0000-0000-000000000001', 'd1111111-1111-1111-1111-111111111111', 100, 'compra', 0.5),
    ('92220000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-00000000000a',  60, 'hotel',  0.5);

do $$ begin
    perform pg_temp.af('M00',
        (select count(*) from public.group_members
          where group_id in ('91110000-0000-0000-0000-000000000001',
                             '92220000-0000-0000-0000-000000000002',
                             '93330000-0000-0000-0000-000000000003')) = 6,
        'montaje: tres grupos con dos personas cada uno');
end $$;

-- Se guardan los tokens que van creándose, para usarlos después de cambiar
-- de usuario. Es una tabla temporal: no existe fuera de esta sesión.
create temporary table tokens (nombre text primary key, token text not null, id uuid);

-- `token_hash` no es legible para `authenticated` —eso lo comprueba I33—, así
-- que las aserciones que la miran se hacen como `postgres`, y el resto de la
-- prueba trabaja con el `id`, que sí está concedido. Esta línea lo rellena
-- después de cada creación.
grant insert, select, update on tokens to authenticated, anon;

-- ============================================================
--  H1 · Nadie entra en un grupo sin decidirlo
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"b0000000-0000-0000-0000-00000000000b"}';

do $$
declare bloqueado boolean;
begin
    -- Amigo1 está en «Viaje» y conoce el UUID de Alba porque comparten grupo.
    -- Antes de 0010 podía meter a quien quisiera en «Ajeno».
    begin
        insert into public.group_members (group_id, user_id, role)
        values ('93330000-0000-0000-0000-000000000003',
                'a0000000-0000-0000-0000-00000000000a', 'member');
        bloqueado := false;
    exception when insufficient_privilege or check_violation then bloqueado := true;
    end;
    perform pg_temp.af('H1a', bloqueado,
        'H1 · un miembro NO puede insertar a otra persona en su grupo');
end $$;

do $$
declare bloqueado boolean;
begin
    -- La segunda puerta: reescribir el user_id de una membresía existente.
    -- Amigo1 es propietario de «Ajeno», así que `miembros_cambiar_rol` le
    -- deja actualizar; lo que ahora se lo impide es el privilegio de columna.
    begin
        update public.group_members
           set user_id = 'a0000000-0000-0000-0000-00000000000a'
         where group_id = '93330000-0000-0000-0000-000000000003'
           and user_id  = 'e0000000-0000-0000-0000-00000000000e';
        bloqueado := false;
    exception when insufficient_privilege then bloqueado := true;
    end;
    perform pg_temp.af('H1b', bloqueado,
        'H1 · ni siquiera un propietario puede reescribir el user_id de una membresía');
end $$;

do $$
declare tocadas integer;
begin
    -- Lo que SÍ tiene que seguir funcionando: cambiar el rol.
    with c as (
        update public.group_members set role = 'owner'
         where group_id = '93330000-0000-0000-0000-000000000003'
           and user_id  = 'e0000000-0000-0000-0000-00000000000e'
        returning 1)
    select count(*) into tocadas from c;
    perform pg_temp.af('H1c', tocadas = 1,
        'H1 · un propietario SIGUE pudiendo cambiar el rol de un miembro');

    update public.group_members set role = 'member'
     where group_id = '93330000-0000-0000-0000-000000000003'
       and user_id  = 'e0000000-0000-0000-0000-00000000000e';
end $$;

-- El creador de un grupo sí puede apuntarse a sí mismo: es la red de
-- seguridad que usa js/supabase-data.js → crearGrupo() si el trigger
-- `apuntar_creador_como_miembro` no llegara a ejecutarse. Sin ella, crear un
-- grupo fallaría en ese caso degradado y el grupo quedaría invisible.
--
-- Se reproduce el caso de verdad: un grupo con creador y CERO miembros. Se
-- consigue insertándolo sin creador —el trigger AFTER solo apunta a alguien
-- si `created_by` viene relleno— y poniéndoselo después.
set local role postgres;
-- OJO: hay que limpiar el JWT antes de insertar. El trigger BEFORE
-- `registrar_creador_del_grupo` rellena `created_by` con `auth.uid()` cuando
-- viene nulo, y con la sesión de la aserción anterior todavía puesta el grupo
-- nacería con un creador —y por tanto con un miembro— que no queremos aquí.
-- Sin esta línea la prueba pasaba por el motivo equivocado.
set local request.jwt.claims = '{}';   -- sin `sub`: sesión ausente
insert into public.groups (id, name, created_by)
values ('94440000-0000-0000-0000-000000000004', 'Huerfano', null);
update public.groups set created_by = 'c0000000-0000-0000-0000-00000000000c'
 where id = '94440000-0000-0000-0000-000000000004';

do $$ begin
    perform pg_temp.af('H1d0',
        (select count(*) from public.group_members
          where group_id = '94440000-0000-0000-0000-000000000004') = 0,
        'H1 · el grupo huérfano nace de verdad sin ningún miembro');
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"c0000000-0000-0000-0000-00000000000c"}';
do $$
declare n integer; bloqueado boolean;
begin
    perform pg_temp.af('H1d',
        (select count(*) from public.group_members
          where group_id = '94440000-0000-0000-0000-000000000004') = 0,
        'H1 · punto de partida: un grupo con creador y ningún miembro');

    insert into public.group_members (group_id, user_id, role)
    values ('94440000-0000-0000-0000-000000000004', auth.uid(), 'owner');

    select count(*) into n from public.group_members
     where group_id = '94440000-0000-0000-0000-000000000004';
    perform pg_temp.af('H1e', n = 1,
        'H1 · quien creó el grupo SÍ puede apuntarse a sí mismo (red de seguridad del cliente)');

    -- Pero ni siquiera el creador puede aprovechar esa rama para meter a otro.
    begin
        insert into public.group_members (group_id, user_id, role)
        values ('94440000-0000-0000-0000-000000000004',
                'a0000000-0000-0000-0000-00000000000a', 'member');
        bloqueado := false;
    exception when insufficient_privilege or check_violation then bloqueado := true;
    end;
    perform pg_temp.af('H1f', bloqueado,
        'H1 · y el creador tampoco puede colar a un tercero por esa rama');
end $$;

-- Se borra el GRUPO, no las membresías: el trigger que protege al último
-- propietario impide vaciar un grupo vivo, y en cambio deja pasar el borrado
-- en cascada cuando el grupo ya no está.
set local role postgres;
delete from public.groups where id = '94440000-0000-0000-0000-000000000004';
set local role authenticated;

-- ============================================================
--  H2 · Las funciones de pertenencia ya no son un oráculo
-- ============================================================
set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e"}';

do $$
begin
    -- El extraño solo está en «Ajeno». Pregunta por un grupo que no ve.
    perform pg_temp.af('H2a',
        public.es_miembro('92220000-0000-0000-0000-000000000002',
                          'a0000000-0000-0000-0000-00000000000a') = false,
        'H2 · es_miembro NO confirma que un tercero esté en un grupo ajeno');

    perform pg_temp.af('H2b',
        public.es_owner('92220000-0000-0000-0000-000000000002',
                        'a0000000-0000-0000-0000-00000000000a') = false,
        'H2 · es_owner tampoco');

    perform pg_temp.af('H2c',
        public.es_miembro('91110000-0000-0000-0000-000000000001',
                          'd2222222-2222-2222-2222-222222222222') = false,
        'H2 · ni sobre el grupo heredado de Dani y Pilar');

    -- Y lo que SÍ tiene que seguir respondiendo:
    perform pg_temp.af('H2d',
        public.es_miembro('93330000-0000-0000-0000-000000000003') = true,
        'H2 · sobre uno mismo en el grupo propio sigue respondiendo la verdad');

    perform pg_temp.af('H2e',
        public.es_miembro('93330000-0000-0000-0000-000000000003',
                          'b0000000-0000-0000-0000-00000000000b') = true,
        'H2 · sobre un compañero del grupo propio también (lo necesitan las políticas)');

    perform pg_temp.af('H2f',
        public.es_miembro('92220000-0000-0000-0000-000000000002') = false,
        'H2 · sobre uno mismo en un grupo ajeno responde que no, que es la verdad');
end $$;

-- ============================================================
--  1 · Invitación válida, de punta a punta
-- ============================================================
set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a"}';

do $$
declare t text;
begin
    t := public.crear_invitacion('92220000-0000-0000-0000-000000000002');
    insert into tokens (nombre, token) values ('viaje', t);

    perform pg_temp.af('I01', t ~ '^[A-Za-z0-9_-]{43}$',
        'el token son 43 caracteres aptos para una URL');

    perform pg_temp.af('I02',
        (select count(*) from public.group_invitations
          where group_id = '92220000-0000-0000-0000-000000000002') = 1,
        'la invitación queda registrada');

    perform pg_temp.af('I05',
        (select caduca_en::date from public.group_invitations
          where group_id = '92220000-0000-0000-0000-000000000002')
        = (now() + interval '7 days')::date,
        'caduca a los 7 días, que es lo acordado');

    perform pg_temp.af('I06',
        (select max_usos is null and usos = 0 from public.group_invitations
          where group_id = '92220000-0000-0000-0000-000000000002'),
        'usos ilimitados por defecto, y contador a cero');
end $$;

set local role postgres;
update tokens set id = (select i.id from public.group_invitations i
                         where i.token_hash = sha256(convert_to(tokens.token, 'UTF8')))
 where id is null;

do $$
declare t text := (select token from tokens where nombre = 'viaje');
begin
    perform pg_temp.af('I03',
        not exists (select 1 from public.group_invitations
                     where token_hash = convert_to(t, 'UTF8')),
        'el token NO está guardado en claro');

    perform pg_temp.af('I04',
        exists (select 1 from public.group_invitations
                 where token_hash = sha256(convert_to(t, 'UTF8'))),
        'lo que se guarda es su SHA-256, y solo eso');
end $$;

set local role authenticated;

-- Amigo2 abre el enlace
set local request.jwt.claims = '{"sub":"c0000000-0000-0000-0000-00000000000c"}';

do $$
declare v record;
begin
    select * into v from public.ver_invitacion((select token from tokens where nombre='viaje'));

    perform pg_temp.af('I07', v.estado = 'valida', 'ver_invitacion la da por válida');
    perform pg_temp.af('I08', v.grupo = 'Viaje',   'y dice a qué grupo te invitan');
    perform pg_temp.af('I09', v.invita = 'Alba',   'y quién te invita');
    perform pg_temp.af('I10', v.ya_soy_miembro = false, 'y que todavía no eres miembro');

    perform pg_temp.af('I11',
        (select count(*) from public.groups) = 0,
        'antes de aceptar, Amigo2 no ve ningún grupo');
end $$;

do $$
declare v record;
begin
    select * into v from public.aceptar_invitacion((select token from tokens where nombre='viaje'));

    perform pg_temp.af('I12', v.resultado = 'aceptada', 'aceptar la invitación funciona');
    perform pg_temp.af('I13', v.grupo_id = '92220000-0000-0000-0000-000000000002',
        'y devuelve el grupo, para que la interfaz pueda entrar en él');

    perform pg_temp.af('I14',
        (select role from public.group_members
          where group_id = v.grupo_id and user_id = auth.uid()) = 'member',
        'quien entra por invitación es «member», nunca «owner»');

    perform pg_temp.af('I15',
        (select count(*) from public.groups) = 1
        and (select name from public.groups) = 'Viaje',
        'ahora Amigo2 ve ese grupo, y SOLO ese');

    perform pg_temp.af('I16', (select count(*) from public.expenses) = 1,
        'y sus gastos');
end $$;

set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a"}';
do $$ begin
    perform pg_temp.af('I17',
        (select usos from public.group_invitations
          where group_id = '92220000-0000-0000-0000-000000000002') = 1,
        'el contador de usos sube a 1');
    perform pg_temp.af('I18',
        (select count(*) from public.group_members
          where group_id = '92220000-0000-0000-0000-000000000002') = 3,
        'el grupo de Alba tiene ya tres personas');
end $$;

-- ============================================================
--  2 · Token inventado   ·   12 · Enumeración
-- ============================================================
set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e"}';

do $$
declare v record; i integer; distintos integer := 0;
begin
    select * into v from public.ver_invitacion('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    perform pg_temp.af('I19', v.estado = 'desconocida' and v.grupo is null,
        'un token inventado es «desconocida» y no dice nada más');

    select * into v from public.aceptar_invitacion('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    perform pg_temp.af('I20', v.resultado = 'desconocida' and v.grupo_id is null,
        'y aceptarlo no mete a nadie en ningún sitio');

    -- Formatos raros: ni llegan a la tabla.
    select * into v from public.ver_invitacion('');
    perform pg_temp.af('I21', v.estado = 'desconocida', 'un token vacío se rechaza por formato');
    select * into v from public.ver_invitacion(null);
    perform pg_temp.af('I22', v.estado = 'desconocida', 'y un token nulo también');
    select * into v from public.ver_invitacion(repeat('x', 500));
    perform pg_temp.af('I23', v.estado = 'desconocida', 'y uno de 500 caracteres');
    select * into v from public.ver_invitacion(''' or 1=1 --');
    perform pg_temp.af('I24', v.estado = 'desconocida', 'y uno con comillas y SQL dentro');

    -- Enumeración: 200 tokens al azar, ninguno acierta.
    for i in 1..200 loop
        select * into v from public.ver_invitacion(
            translate(rtrim(replace(encode(decode(replace(gen_random_uuid()::text,'-','') ||
                replace(gen_random_uuid()::text,'-',''), 'hex'), 'base64'), E'\n',''), '='), '+/', '-_'));
        if v.estado <> 'desconocida' then distintos := distintos + 1; end if;
    end loop;
    perform pg_temp.af('I25', distintos = 0,
        '200 tokens al azar: ninguno acierta (el espacio es de 2^244)');

    perform pg_temp.af('I26',
        (select count(*) from public.group_invitations) = 0,
        'el extraño no ve NINGUNA invitación, ni la de Alba');
end $$;

-- ============================================================
--  11 · ver_invitacion no puede devolver el group_id
--
--  No es que se le olvide rellenarlo: es que su tipo de retorno no tiene
--  dónde ponerlo. Por eso se comprueba contra el catálogo y no ejecutándola:
--  una comprobación de ejecución solo diría «esta vez no lo devolvió».
-- ============================================================
do $$
declare n integer;
begin
    select count(*) into n
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace,
      lateral unnest(coalesce(p.proallargtypes, array[]::oid[])) as t(tipo)
     where ns.nspname = 'public' and p.proname = 'ver_invitacion'
       and t.tipo = 'uuid'::regtype;

    perform pg_temp.af('I27', n = 0,
        'ver_invitacion no tiene NINGÚN parámetro ni columna de tipo uuid');
end $$;

-- ============================================================
--  9 · La RPC no admite un user_id ajeno
--
--  Tampoco es una comprobación que se pueda olvidar: `aceptar_invitacion`
--  tiene UN argumento y es el token. No hay forma de expresar «mete a otro».
-- ============================================================
do $$
declare n integer; args text;
begin
    select p.pronargs, pg_get_function_identity_arguments(p.oid) into n, args
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = 'aceptar_invitacion';

    perform pg_temp.af('I28', n = 1 and args = 'p_token text',
        'aceptar_invitacion(p_token text): un solo argumento, ningún user_id que rellenar');

    perform pg_temp.af('I28b', args not like '%uuid%',
        'y ninguno de tipo uuid: no hay dónde meter la identidad de otra persona');
end $$;

do $$
declare fallo boolean;
begin
    begin
        execute 'select public.aceptar_invitacion($1, $2)'
          using (select token from tokens where nombre = 'viaje'),
                'a0000000-0000-0000-0000-00000000000a'::uuid;
        fallo := false;
    exception when undefined_function or syntax_error_or_access_rule_violation
                 or invalid_text_representation then fallo := true;
    end;
    perform pg_temp.af('I29', fallo,
        'llamarla con un segundo argumento no existe como función');
end $$;

-- ============================================================
--  10 · Invitaciones de grupos ajenos
-- ============================================================
set local request.jwt.claims = '{"sub":"b0000000-0000-0000-0000-00000000000b"}';
do $$ begin
    -- Amigo1 SÍ está en «Viaje», así que ve la invitación de ese grupo...
    perform pg_temp.af('I30',
        (select count(*) from public.group_invitations) = 1,
        'un miembro ve las invitaciones de SU grupo, para poder revocarlas');
end $$;

set local request.jwt.claims = '{"sub":"d1111111-1111-1111-1111-111111111111"}';
do $$ begin
    perform pg_temp.af('I31',
        (select count(*) from public.group_invitations) = 0,
        'Dani no ve ninguna invitación: no está en el grupo de Alba');

    perform pg_temp.af('I32',
        (select count(*) from public.group_invitations
          where group_id = '92220000-0000-0000-0000-000000000002') = 0,
        'ni preguntando directamente por el group_id de Alba');
end $$;

do $$
declare bloqueado boolean;
begin
    begin
        perform token_hash from public.group_invitations limit 1;
        bloqueado := false;
    exception when insufficient_privilege then bloqueado := true;
    end;
    perform pg_temp.af('I33', bloqueado,
        'la columna token_hash no es legible ni para un miembro');
end $$;

-- ============================================================
--  4 · Revocada     ·     y quién puede revocar
-- ============================================================
set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e"}';
do $$
declare id_ajena uuid;
begin
    -- El extraño no ve la invitación, pero se le da el id igualmente: aunque
    -- lo consiguiera por otro camino, no debe poder revocarla.
    select id into id_ajena from public.group_invitations;   -- vacío para él
    perform pg_temp.af('I34', id_ajena is null,
        'el extraño no puede ni obtener el id de una invitación ajena');
end $$;

set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a"}';
do $$
begin
    insert into tokens (nombre, token)
    values ('revocar', public.crear_invitacion('92220000-0000-0000-0000-000000000002'));
end $$;

-- Sincroniza el id de cada token. Se hace por `token_hash` y como `postgres`,
-- que es la única identidad fiable: `creada_en` vale `now()`, que en
-- PostgreSQL es la hora de la TRANSACCIÓN, así que todas las invitaciones de
-- esta prueba comparten marca de tiempo y «la más reciente» no distingue
-- ninguna. En producción no pasa —cada RPC es su propia transacción— pero
-- aquí llegó a revocar la invitación equivocada.
set local role postgres;
update tokens set id = (select i.id from public.group_invitations i
                         where i.token_hash = sha256(convert_to(tokens.token, 'UTF8')))
 where id is null;
set local role authenticated;

set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a"}';
do $$
declare v_id uuid := (select id from tokens where nombre = 'revocar');
begin
    perform pg_temp.af('I34b', v_id is not null,
        'la invitación a revocar se identifica por su hash, no por la hora');

    -- Un extraño con el id en la mano no la revoca.
    perform set_config('request.jwt.claims',
        '{"sub":"e0000000-0000-0000-0000-00000000000e"}', true);
    perform pg_temp.af('I35', public.revocar_invitacion(v_id) = false,
        'un extraño con el id de una invitación ajena NO puede revocarla');

    -- Se vuelve a Alba para poder MIRAR la invitación: el extraño ni la ve,
    -- así que preguntándoselo a él la comprobación saldría nula y pasaría por
    -- el motivo equivocado.
    perform set_config('request.jwt.claims',
        '{"sub":"a0000000-0000-0000-0000-00000000000a"}', true);
    perform pg_temp.af('I36',
        (select revocada_en is null from public.group_invitations where id = v_id),
        'y la invitación sigue viva');
    perform pg_temp.af('I37', public.revocar_invitacion(v_id) = true,
        'quien la creó sí puede revocarla');
    perform pg_temp.af('I38', public.revocar_invitacion(v_id) = false,
        'revocar dos veces devuelve false, no rompe nada');
end $$;

set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e"}';
do $$
declare v record;
begin
    select * into v from public.ver_invitacion((select token from tokens where nombre='revocar'));
    perform pg_temp.af('I39', v.estado = 'revocada', 'una invitación revocada se ve como tal');
    perform pg_temp.af('I40', v.grupo is null,
        'y NO dice a qué grupo pertenecía: un enlace muerto no filtra el nombre');

    select * into v from public.aceptar_invitacion((select token from tokens where nombre='revocar'));
    perform pg_temp.af('I41', v.resultado = 'revocada' and v.grupo_id is null,
        'y aceptarla no mete a nadie');
    perform pg_temp.af('I42', (select count(*) from public.groups) = 1,
        'el extraño sigue viendo solo su grupo');
end $$;

-- ============================================================
--  3 · Caducada
--
--  Se envejece la fila a mano, que es la única forma de probar el paso del
--  tiempo sin esperar siete días.
-- ============================================================
set local role postgres;
insert into tokens (nombre, token) values ('caducada', 'CADUCADAcaducadaCADUCADAcaducadaCADUCADAcad');
insert into public.group_invitations (group_id, creada_por, token_hash, creada_en, caduca_en)
values ('92220000-0000-0000-0000-000000000002',
        'a0000000-0000-0000-0000-00000000000a',
        sha256(convert_to('CADUCADAcaducadaCADUCADAcaducadaCADUCADAcad', 'UTF8')),
        now() - interval '10 days', now() - interval '3 days');

set local role authenticated;
set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e"}';
do $$
declare v record;
begin
    select * into v from public.ver_invitacion((select token from tokens where nombre='caducada'));
    perform pg_temp.af('I43', v.estado = 'caducada', 'una invitación pasada de fecha es «caducada»');
    perform pg_temp.af('I44', v.grupo is null, 'y tampoco dice de qué grupo era');

    select * into v from public.aceptar_invitacion((select token from tokens where nombre='caducada'));
    perform pg_temp.af('I45', v.resultado = 'caducada', 'y no se puede aceptar');
    perform pg_temp.af('I46',
        not public.es_miembro('92220000-0000-0000-0000-000000000002'),
        'el extraño NO ha entrado en el grupo de Alba');
end $$;

-- ============================================================
--  5 · Agotada (max_usos)
-- ============================================================
set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a"}';
do $$
begin
    insert into tokens (nombre, token)
    values ('una_vez', public.crear_invitacion('92220000-0000-0000-0000-000000000002', 7, 1));
end $$;

-- Sincroniza el id de cada token. Se hace por `token_hash` y como `postgres`,
-- que es la única identidad fiable: `creada_en` vale `now()`, que en
-- PostgreSQL es la hora de la TRANSACCIÓN, así que todas las invitaciones de
-- esta prueba comparten marca de tiempo y «la más reciente» no distingue
-- ninguna. En producción no pasa —cada RPC es su propia transacción— pero
-- aquí llegó a revocar la invitación equivocada.
set local role postgres;
update tokens set id = (select i.id from public.group_invitations i
                         where i.token_hash = sha256(convert_to(tokens.token, 'UTF8')))
 where id is null;
set local role authenticated;

set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a"}';
do $$ begin
    perform pg_temp.af('I47',
        (select max_usos from public.group_invitations
          where id = (select id from tokens where nombre = 'una_vez')) = 1,
        'se puede crear una invitación de un solo uso');
end $$;

-- La gasta Extraño...
set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e"}';
do $$
declare v record;
begin
    select * into v from public.aceptar_invitacion((select token from tokens where nombre='una_vez'));
    perform pg_temp.af('I48', v.resultado = 'aceptada', 'el primero la usa');
end $$;

-- ...y ya no le sirve a Dani.
set local request.jwt.claims = '{"sub":"d1111111-1111-1111-1111-111111111111"}';
do $$
declare v record;
begin
    select * into v from public.ver_invitacion((select token from tokens where nombre='una_vez'));
    perform pg_temp.af('I49', v.estado = 'agotada', 'para el segundo está «agotada»');

    select * into v from public.aceptar_invitacion((select token from tokens where nombre='una_vez'));
    perform pg_temp.af('I50', v.resultado = 'agotada' and v.grupo_id is null,
        'y no le deja entrar');
    perform pg_temp.af('I51',
        not public.es_miembro('92220000-0000-0000-0000-000000000002'),
        'Dani sigue fuera del grupo de Alba');
end $$;

-- ============================================================
--  6 · Quien ya es miembro
-- ============================================================
set local request.jwt.claims = '{"sub":"c0000000-0000-0000-0000-00000000000c"}';
do $$
declare v record; usos_antes integer; usos_despues integer; miembros_antes integer;
begin
    select usos into usos_antes from public.group_invitations
     where id = (select id from tokens where nombre = 'viaje');
    select count(*) into miembros_antes from public.group_members
     where group_id = '92220000-0000-0000-0000-000000000002';

    select * into v from public.aceptar_invitacion((select token from tokens where nombre='viaje'));

    perform pg_temp.af('I52', v.resultado = 'ya_eras_miembro',
        'volver a abrir el enlace siendo ya miembro no es un error');
    perform pg_temp.af('I53', v.grupo_id = '92220000-0000-0000-0000-000000000002',
        'y devuelve el grupo igual, para poder entrar en él');

    select usos into usos_despues from public.group_invitations
     where id = (select id from tokens where nombre = 'viaje');
    perform pg_temp.af('I54', usos_despues = usos_antes,
        'el contador de usos NO sube: no ha entrado nadie nuevo');
    perform pg_temp.af('I55',
        (select count(*) from public.group_members
          where group_id = '92220000-0000-0000-0000-000000000002') = miembros_antes,
        'ni se duplica la membresía');
end $$;

-- ============================================================
--  7 · Sin sesión
-- ============================================================
set local request.jwt.claims = '{}';   -- sin `sub`: sesión ausente
do $$
declare fallo boolean;
begin
    begin
        perform public.aceptar_invitacion((select token from tokens where nombre='viaje'));
        fallo := false;
    exception when insufficient_privilege then fallo := true;
    end;
    perform pg_temp.af('I56', fallo, 'sin sesión, aceptar_invitacion se niega');

    begin
        perform public.ver_invitacion((select token from tokens where nombre='viaje'));
        fallo := false;
    exception when insufficient_privilege then fallo := true;
    end;
    perform pg_temp.af('I57', fallo, 'y ver_invitacion también');

    begin
        perform public.crear_invitacion('92220000-0000-0000-0000-000000000002');
        fallo := false;
    exception when insufficient_privilege then fallo := true;
    end;
    perform pg_temp.af('I58', fallo, 'y crear_invitacion');
end $$;

-- El rol anónimo ni siquiera puede invocarlas.
set local role anon;
do $$
declare fallo boolean;
begin
    begin
        perform public.ver_invitacion('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
        fallo := false;
    exception when insufficient_privilege then fallo := true;
    end;
    perform pg_temp.af('I59', fallo,
        'el rol anon no tiene EXECUTE: un enlace sin iniciar sesión no revela nada');
end $$;

-- ============================================================
--  Quién puede crear una invitación
-- ============================================================
set local role authenticated;
set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e"}';
do $$
declare fallo boolean;
begin
    begin
        perform public.crear_invitacion('91110000-0000-0000-0000-000000000001');
        fallo := false;
    exception when insufficient_privilege then fallo := true;
    end;
    perform pg_temp.af('I60', fallo,
        'no se puede crear una invitación para un grupo del que no eres miembro');

    begin
        perform public.crear_invitacion('92220000-0000-0000-0000-000000000002', 0);
        fallo := false;
    exception when others then fallo := true;
    end;
    perform pg_temp.af('I61', fallo, 'ni con una caducidad de 0 días');
end $$;

-- ============================================================
--  14 · Dani, Pilar y su grupo, exactamente igual que antes
-- ============================================================
set local request.jwt.claims = '{"sub":"d1111111-1111-1111-1111-111111111111"}';
do $$ begin
    perform pg_temp.af('V01',
        (select count(*) from public.groups where id = '91110000-0000-0000-0000-000000000001') = 1,
        'Dani sigue viendo su grupo de siempre');
    perform pg_temp.af('V02',
        (select count(*) from public.group_members
          where group_id = '91110000-0000-0000-0000-000000000001') = 2,
        'que sigue teniendo exactamente dos personas');
    perform pg_temp.af('V03',
        (select count(*) from public.expenses
          where group_id = '91110000-0000-0000-0000-000000000001') = 1,
        'y su gasto intacto');
    perform pg_temp.af('V04',
        public.saldo_centimos('91110000-0000-0000-0000-000000000001',
                              'd1111111-1111-1111-1111-111111111111',
                              'd2222222-2222-2222-2222-222222222222') = 5000,
        'y el saldo sale igual que antes: 50,00 € a favor de Dani');
    perform pg_temp.af('V05',
        (select count(*) from public.groups) = 1,
        'Dani NO ve el grupo de Alba, ni el del amigo, ni el nuevo de nadie');
    perform pg_temp.af('V06',
        (select count(*) from public.profiles) = 2,
        'ni los perfiles de gente con la que no comparte grupo');
end $$;

-- ============================================================
--  15 · Aislamiento final, con los tres grupos ya poblados
-- ============================================================
set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a"}';
do $$ begin
    perform pg_temp.af('V07', (select count(*) from public.groups) = 1,
        'Alba ve un solo grupo, el suyo');
    perform pg_temp.af('V08',
        (select count(*) from public.group_members
          where group_id = '92220000-0000-0000-0000-000000000002') = 4,
        'con las cuatro personas que hay dentro');
    perform pg_temp.af('V09',
        (select count(*) from public.profiles) = 4,
        'y los cuatro perfiles, ni uno más');
    perform pg_temp.af('V10',
        (select count(*) from public.profiles where display_name in ('Dani P','Pilar P')) = 0,
        'Alba NO ve a Dani ni a Pilar');
    perform pg_temp.af('V11',
        (select count(*) from public.expenses
          where group_id = '91110000-0000-0000-0000-000000000001') = 0,
        'ni los gastos del grupo heredado');
end $$;

set local request.jwt.claims = '{"sub":"c0000000-0000-0000-0000-00000000000c"}';
do $$ begin
    perform pg_temp.af('V12',
        (select count(*) from public.groups) = 1
        and (select name from public.groups) = 'Viaje',
        'Amigo2, que entró por invitación, ve SOLO el grupo al que le invitaron');
    perform pg_temp.af('V13',
        (select count(*) from public.groups
          where id = '93330000-0000-0000-0000-000000000003') = 0,
        'y no el otro grupo de quien le trajo');
end $$;

-- ------------------------------------------------------------
--  Recuento
-- ------------------------------------------------------------
set local role postgres;
select count(*) || ' aserciones de invitaciones superadas' as resultado from registro_inv;
select string_agg(id, ' ' order by id) as aserciones from registro_inv;

rollback;
