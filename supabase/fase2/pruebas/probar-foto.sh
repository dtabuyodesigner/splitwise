#!/usr/bin/env bash
# ============================================================
#  20_foto.sql, contra un PostgreSQL DESECHABLE
#
#      supabase/fase2/pruebas/probar-foto.sh <url-de-una-base-DESECHABLE>
#
#  El fallo que cubre esta prueba: `tomar_foto()` es `language sql`, y
#  PostgreSQL analiza su cuerpo entero al crearla. Una referencia literal a
#  `public.group_members` hacía fallar el CREATE FUNCTION con «no existe la
#  relación» justo en el momento que importa: la fotografía de ANTES de
#  migrar, cuando la tabla todavía no existe.
#
#  Se comprueban los dos estados: sin la tabla y con la tabla y filas.
# ============================================================
set -Eeuo pipefail

URL="${1:-}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
[ -z "$URL" ] && { echo "Uso: $0 <url-de-una-base-DESECHABLE>" >&2; exit 64; }

total=0; fallos=0
comprobar() {
    total=$((total + 1))
    if [ "$3" -eq 0 ]; then echo "  [$1] ok — $2"
    else echo "  [$1] FALLA — $2"; fallos=$((fallos + 1)); fi
}
consulta() { psql "$URL" -X -A -t -q -v ON_ERROR_STOP=1 -c "$1" </dev/null | tr -d '[:space:]'; }
valor_de() {
    consulta "select valor from public.foto_validacion
               where momento = '$1' and ambito = 'recuento' and clave = '$2'"
}

echo "── F · La fotografía, con y sin group_members ──"

# El escenario histórico: el estado real de producción antes de migrar,
# incluida la aplicación de viajes y sin group_members.
psql "$URL" -X -q -v ON_ERROR_STOP=1 -f "$RAIZ/supabase/pruebas/00_stub_supabase.sql"   </dev/null >/dev/null
psql "$URL" -X -q -v ON_ERROR_STOP=1 -f "$RAIZ/supabase/pruebas/01_escenario_historico.sql" </dev/null >/dev/null

[ "$(consulta "select to_regclass('public.group_members') is null")" = "t" ] \
    || { echo "El escenario de partida ya trae group_members: la prueba no valdría" >&2; exit 1; }

# ── 1 · Sin la tabla ─────────────────────────────────────────
SALIDA=$(psql "$URL" -X -q -v ON_ERROR_STOP=1 -v momento=antes \
             -f "$RAIZ/supabase/fase2/20_foto.sql" </dev/null 2>&1) && CODIGO=0 || CODIGO=$?
comprobar F01 "group_members ausente · 20_foto.sql no falla al crear la función" "$CODIGO"
if [ "$CODIGO" -ne 0 ]; then printf '%s\n' "$SALIDA" >&2; fi

comprobar F02 "group_members ausente · se guarda exactamente TABLA-AUSENTE" \
    "$([ "$(valor_de antes group_members)" = "TABLA-AUSENTE" ] && echo 0 || echo 1)"

comprobar F03 "group_members ausente · NO se ha creado ninguna tabla ficticia" \
    "$([ "$(consulta "select to_regclass('public.group_members') is null")" = "t" ] && echo 0 || echo 1)"

# El resto de la fotografía tiene que haberse capturado igualmente.
comprobar F04 "group_members ausente · el resto de la fotografía se captura" \
    "$([ "$(consulta "select count(*) from public.foto_validacion where momento='antes'")" -gt 50 ] && echo 0 || echo 1)"
comprobar F05 "group_members ausente · la frontera de viajes entra en la foto" \
    "$([ "$(consulta "select count(*) from public.foto_validacion
                       where momento='antes' and ambito like 'viajes:%'")" -gt 0 ] && echo 0 || echo 1)"

# ── 2 · Con la tabla y con filas ─────────────────────────────
# Una tabla de verdad, no un sustituto de la migración: aquí solo se prueba
# que el recuento se lee cuando la tabla existe.
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null >/dev/null <<'SQL'
create table public.group_members (
    group_id uuid not null,
    user_id  uuid not null,
    rol      text not null default 'miembro',
    primary key (group_id, user_id)
);
insert into public.group_members (group_id, user_id, rol)
select g.id, p.id, 'propietario' from public.groups g cross join public.profiles p;
SQL
ESPERADAS="$(consulta "select count(*) from public.group_members")"

SALIDA=$(psql "$URL" -X -q -v ON_ERROR_STOP=1 -v momento=despues \
             -f "$RAIZ/supabase/fase2/20_foto.sql" </dev/null 2>&1) && CODIGO=0 || CODIGO=$?
comprobar F06 "group_members presente · 20_foto.sql tampoco falla" "$CODIGO"
if [ "$CODIGO" -ne 0 ]; then printf '%s\n' "$SALIDA" >&2; fi

comprobar F07 "group_members presente · se guarda el recuento real ($ESPERADAS)" \
    "$([ "$(valor_de despues group_members)" = "$ESPERADAS" ] && echo 0 || echo 1)"

comprobar F08 "la foto de ANTES no se ha alterado al tomar la de DESPUES" \
    "$([ "$(valor_de antes group_members)" = "TABLA-AUSENTE" ] && echo 0 || echo 1)"

# ── 3 · Los datos históricos no se tocan ─────────────────────
comprobar F09 "fotografiar no cambia los datos históricos" \
    "$([ "$(consulta "select count(*) from public.expenses")" = "53" ] \
       && [ "$(consulta "select count(*) from public.groups")" = "3" ] \
       && [ "$(consulta "select count(*) from public.profiles")" = "2" ] && echo 0 || echo 1)"

# ── 3b · Realtime de las tablas de gastos, fuera de la frontera de viajes ──
# El escenario historico ya publica las tablas de VIAJES en supabase_realtime,
# asi que esto comprueba de verdad que los dos ambitos no se mezclan.
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null >/dev/null <<'SQL'
alter publication supabase_realtime add table public.expenses;
alter publication supabase_realtime add table public.groups;
SQL
psql "$URL" -X -q -v ON_ERROR_STOP=1 -v momento=realtime \
     -f "$RAIZ/supabase/fase2/20_foto.sql" </dev/null >/dev/null
comprobar F10 "las tablas de gastos publicadas se capturan en el ambito 'realtime'" \
    "$([ "$(consulta "select string_agg(clave, ',' order by clave) from public.foto_validacion
                       where momento='realtime' and ambito='realtime'")" = "expenses,groups" ] && echo 0 || echo 1)"
comprobar F11 "el ambito 'realtime' NO absorbe las tablas de viajes publicadas" \
    "$([ "$(consulta "select count(*) from public.foto_validacion
                       where momento='realtime' and ambito='realtime'
                         and clave in ('viajes','viaje_diario','viaje_fotos')")" = "0" ] && echo 0 || echo 1)"
comprobar F12 "viajes:realtime sigue capturando las suyas, por separado" \
    "$([ "$(consulta "select count(*) from public.foto_validacion
                       where momento='realtime' and ambito='viajes:realtime'")" = "2" ] && echo 0 || echo 1)"

# ── 4 · La auxiliar, en sus dos casos ────────────────────────
comprobar F13 "contar_si_existe(NULL) devuelve TABLA-AUSENTE" \
    "$([ "$(consulta "select public.contar_si_existe(to_regclass('public.no_existe_esta_tabla'))")" = "TABLA-AUSENTE" ] && echo 0 || echo 1)"
comprobar F14 "contar_si_existe(tabla real) devuelve su recuento" \
    "$([ "$(consulta "select public.contar_si_existe(to_regclass('public.expenses'))")" = "53" ] && echo 0 || echo 1)"

echo "════ $((total - fallos))/$total aserciones superadas ════"
[ "$fallos" -eq 0 ] || { echo "FALLOS: $fallos"; exit 1; }
