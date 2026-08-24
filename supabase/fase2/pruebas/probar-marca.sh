#!/usr/bin/env bash
# ============================================================
#  Prueba de la marca contra un PostgreSQL DESECHABLE
#
#      supabase/fase2/pruebas/probar-marca.sh "$URL_DESECHABLE"
#
#  Aquí sí hay psql de verdad, así que se comprueba la guarda contra una base
#  real: sin marca, con marca incorrecta, con marca correcta, y con la
#  consulta rota. La base la crea el CI y se tira al terminar.
#
#  NUNCA debe apuntar a nada que no sea desechable. La propia guarda lo
#  impide para hosts de Supabase.
# ============================================================
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDA="$AQUI/../guarda-no-produccion.sh"
URL="${1:-}"

[ -z "$URL" ] && { echo "Uso: $0 <url-de-una-base-DESECHABLE>" >&2; exit 64; }

fallos=0; total=0
afirmar() {
    total=$((total + 1))
    if [ "$3" -eq 0 ]; then echo "  [$1] ok — $2"
    else echo "  [$1] FALLA — $2"; fallos=$((fallos + 1)); fi
}

sin_url() {  # ninguna salida puede contener la cadena de conexión
    ! printf '%s' "$1" | grep -qF "$URL"
}

echo "── C · La marca, contra un PostgreSQL real ──"

# C1 · Sin la tabla
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null \
     -c "drop table if exists public.copia_de_validacion" >/dev/null
out=$("$GUARDA" "$URL" 2>&1 </dev/null); codigo=$?
[ "$codigo" -ne 0 ]; afirmar C1 "sin la tabla de marca · aborta" $?
sin_url "$out";      afirmar C1-url "sin la tabla · no imprime la cadena" $?

# C2 · Tabla presente pero con un sello que no es el nuestro
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null >/dev/null <<'SQL'
create table public.copia_de_validacion (
    sello text not null, marcada_en timestamptz default now(), nota text not null);
insert into public.copia_de_validacion (sello, nota) values ('OTRA-COSA', 'sello que no vale');
SQL
out=$("$GUARDA" "$URL" 2>&1 </dev/null); codigo=$?
[ "$codigo" -ne 0 ]; afirmar C2 "marca con sello incorrecto · aborta" $?
sin_url "$out";      afirmar C2-url "sello incorrecto · no imprime la cadena" $?

# C3 · Tabla presente pero VACÍA
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null \
     -c "delete from public.copia_de_validacion" >/dev/null
out=$("$GUARDA" "$URL" 2>&1 </dev/null); codigo=$?
[ "$codigo" -ne 0 ]; afirmar C3 "marca vacía · aborta" $?

# C4 · La marca de verdad, puesta por el script oficial
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null \
     -c "drop table if exists public.copia_de_validacion" >/dev/null
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null \
     -f "$AQUI/../10_marcar_copia.sql" >/dev/null
out=$("$GUARDA" "$URL" 2>&1 </dev/null); codigo=$?
[ "$codigo" -eq 0 ]; afirmar C4 "marca correcta · continúa" $?
sin_url "$out";      afirmar C4-url "marca correcta · no imprime la cadena" $?

# C5 · La consulta de la marca no se puede hacer (base inexistente)
out=$("$GUARDA" "postgresql://localhost:1/base_que_no_existe" 2>&1 </dev/null); codigo=$?
[ "$codigo" -ne 0 ]; afirmar C5 "no se puede consultar la marca · aborta" $?

# C6 · La anonimización se niega si no hay sello
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null \
     -c "update public.copia_de_validacion set sello = 'NO-VALE'" >/dev/null
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null \
     -f "$AQUI/../40_anonimizar.sql" >/dev/null 2>&1
[ $? -ne 0 ]; afirmar C6 "la anonimización se niega sin el sello correcto" $?

# Dejar la base marcada para lo que venga después
psql "$URL" -X -q -v ON_ERROR_STOP=1 </dev/null \
     -c "update public.copia_de_validacion set sello = 'COPIA-DE-VALIDACION-FASE-2'" >/dev/null

echo
echo "════ $((total - fallos))/$total aserciones superadas ════"
[ "$fallos" -eq 0 ] || { echo "FALLOS: $fallos"; exit 1; }
