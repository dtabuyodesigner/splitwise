#!/usr/bin/env bash
# ============================================================
#  Pruebas de las guardas · SIN base de datos y SIN red
#
#      supabase/fase2/pruebas/probar-guardas.sh
#
#  Usa un STUB de psql que anota cada invocación en un fichero testigo. Así
#  no se comprueba solo que la guarda aborte, sino que aborta ANTES de
#  invocar psql: si el testigo tiene algo, es que llegó a intentar conectar.
# ============================================================
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDA="$AQUI/../guarda-no-produccion.sh"
RUNNER="$AQUI/../validar-en-copia.sh"

# Ninguna prueba puede quedarse esperando entrada ni colgarse: todo lo que se
# invoca va con stdin cerrado y con un tope de tiempo.
ejecutar() { timeout 20 "$@" </dev/null; }

BANCO="$(mktemp -d)"
trap 'rm -rf "$BANCO"' EXIT
TESTIGO="$BANCO/psql-invocado.log"

# Stub de psql: anota que le han llamado y devuelve lo que le digamos.
mkdir -p "$BANCO/bin"
cat > "$BANCO/bin/psql" <<'STUB'
#!/usr/bin/env bash
# Una línea por invocación: el SQL puede ocupar varias, así que no se vuelca
# tal cual o el recuento de llamadas saldría mal.
printf 'LLAMADA\n' >> "$PSQL_TESTIGO"
printf '%s\n' "$*" >> "$PSQL_TESTIGO.args"

LLAMADAS=$(grep -c '^LLAMADA$' "$PSQL_TESTIGO")

# Permite que la enésima llamada falle: así se puede probar, por ejemplo,
# que si revienta la fotografía previa no se llega a migrar.
if [ -n "${PSQL_FALLAR_EN_LLAMADA:-}" ] && [ "$LLAMADAS" -eq "$PSQL_FALLAR_EN_LLAMADA" ]; then
    echo "psql (stub): fallo simulado en la llamada $LLAMADAS" >&2
    exit 1
fi

[ -n "${PSQL_SALIDA:-}" ] && printf '%s\n' "$PSQL_SALIDA"
exit "${PSQL_CODIGO:-0}"
STUB
chmod +x "$BANCO/bin/psql"
export PATH="$BANCO/bin:$PATH"
export PSQL_TESTIGO="$TESTIGO"

fallos=0
total=0

# afirmar <id> <descripción> <condición-ya-evaluada:0|1>
afirmar() {
    total=$((total + 1))
    if [ "$3" -eq 0 ]; then
        echo "  [$1] ok — $2"
    else
        echo "  [$1] FALLA — $2"
        fallos=$((fallos + 1))
    fi
}

echo "── B · La guarda rechaza antes de conectar ──"

probar_prohibida() {
    local id="$1" desc="$2" url="$3"
    : > "$TESTIGO"
    local salida codigo
    salida=$(ejecutar "$GUARDA" "$url" 2>&1); codigo=$?

    [ "$codigo" -ne 0 ]; afirmar "$id" "$desc · aborta (salida $codigo)" $?

    # Lo que de verdad importa: no ha llegado a invocar psql.
    [ ! -s "$TESTIGO" ]
    afirmar "$id-psql" "$desc · NO invoca psql" $?

    # Y no ha escupido la cadena de conexión.
    ! printf '%s' "$salida" | grep -qF "$url"
    afirmar "$id-url" "$desc · no imprime la cadena de conexión" $?
}

probar_prohibida B01 "referencia del proyecto real" \
    "postgresql://u:p@db.cmkzcvfjgrgxwqjimtxa.supabase.co:5432/postgres"
probar_prohibida B02 "la misma referencia en MAYÚSCULAS" \
    "postgresql://u:p@db.CMKZCVFJGRGXWQJIMTXA.supabase.co:5432/postgres"
probar_prohibida B03 "otro host de Supabase" \
    "postgresql://u:p@db.otroproyecto.supabase.co:5432/postgres"
probar_prohibida B04 "host .supabase.com" \
    "postgresql://u:p@algo.supabase.com:5432/postgres"

# URL vacía: aborta y tampoco invoca psql
: > "$TESTIGO"
ejecutar "$GUARDA" "" >/dev/null 2>&1; codigo=$?
[ "$codigo" -ne 0 ]; afirmar B05 "URL vacía · aborta (salida $codigo)" $?
[ ! -s "$TESTIGO" ]; afirmar B05-psql "URL vacía · NO invoca psql" $?

echo
echo "── B · Una URL permitida SÍ llega a comprobar la marca ──"

: > "$TESTIGO"
PSQL_SALIDA="SELLO-OK" ejecutar "$GUARDA" "postgresql://localhost:5432/copia_validacion" >/dev/null 2>&1
afirmar B06 "URL local con sello correcto · continúa" $?
[ -s "$TESTIGO" ]; afirmar B06-psql "URL local · SÍ invoca psql para comprobar la marca" $?

: > "$TESTIGO"
PSQL_SALIDA="SELLO-OK" ejecutar "$GUARDA" "postgresql://copia.interna.lan:5433/validacion" >/dev/null 2>&1
afirmar B07 "URL de copia remota permitida · continúa" $?

echo
echo "── C · El sello de copia ──"

comprobar_sello() {
    local id="$1" desc="$2" salida_psql="$3" codigo_psql="$4" espera="$5"
    : > "$TESTIGO"
    local out codigo
    out=$(PSQL_SALIDA="$salida_psql" PSQL_CODIGO="$codigo_psql" \
          ejecutar "$GUARDA" "postgresql://localhost:5432/copia" 2>&1); codigo=$?

    if [ "$espera" = "pasa" ]; then
        [ "$codigo" -eq 0 ]; afirmar "$id" "$desc · continúa" $?
    else
        [ "$codigo" -ne 0 ]; afirmar "$id" "$desc · aborta" $?
    fi
    ! printf '%s' "$out" | grep -q "localhost:5432"
    afirmar "$id-url" "$desc · no imprime la cadena" $?
}

comprobar_sello C01 "sin marca (tabla ausente)"    "SIN-MARCA"      1 aborta
comprobar_sello C02 "marca incorrecta (otro sello)" "SELLO-AUSENTE" 0 aborta
comprobar_sello C03 "marca correcta"                "SELLO-OK"      0 pasa
comprobar_sello C04 "psql falla al consultar"       ""              2 aborta
comprobar_sello C05 "respuesta vacía"               ""              0 aborta

echo
echo "── D · Flujo y códigos de salida ──"

# --dry-run con URL prohibida: no conecta
: > "$TESTIGO"
ejecutar "$RUNNER" "postgresql://u:p@db.cmkzcvfjgrgxwqjimtxa.supabase.co/postgres" --dry-run >/dev/null 2>&1
codigo=$?
[ "$codigo" -ne 0 ]; afirmar D01 "--dry-run con producción · aborta" $?
[ ! -s "$TESTIGO" ]; afirmar D01-psql "--dry-run con producción · NO invoca psql" $?

# --dry-run con URL permitida: pasa la guarda y NO ejecuta nada más
: > "$TESTIGO"
PSQL_SALIDA="SELLO-OK" ejecutar "$RUNNER" "postgresql://localhost:5432/copia" --dry-run >/dev/null 2>&1
afirmar D02 "--dry-run permitido · termina bien" $?
[ "$(grep -c '^LLAMADA$' "$TESTIGO")" -eq 1 ]
afirmar D02-solo "--dry-run permitido · solo la consulta de la marca, nada más" $?

# Si falla la fotografía previa (2ª llamada: la 1ª es la de la marca), no se
# llega a migrar ni a comparar.
: > "$TESTIGO"
salida=$(PSQL_SALIDA="SELLO-OK" PSQL_FALLAR_EN_LLAMADA=2 ejecutar "$RUNNER" \
         "postgresql://localhost:5432/copia" 2>&1); codigo=$?

[ "$codigo" -ne 0 ]; afirmar D03 "falla la fotografía previa · el script aborta" $?
! printf '%s' "$salida" | grep -q "Aplicando las migraciones"
afirmar D03-mig "falla la fotografía previa · NO se aplican migraciones" $?
! printf '%s' "$salida" | grep -q "Comparando antes y después"
afirmar D03-cmp "falla la fotografía previa · NO se compara" $?
! printf '%s' "$salida" | grep -q "Validación sobre la copia completada"
afirmar D03-fin "falla la fotografía previa · NO se declara éxito" $?

# Y si el fallo llega más tarde, tampoco se declara éxito.
: > "$TESTIGO"
salida=$(PSQL_SALIDA="SELLO-OK" PSQL_FALLAR_EN_LLAMADA=3 ejecutar "$RUNNER" \
         "postgresql://localhost:5432/copia" 2>&1); codigo=$?
[ "$codigo" -ne 0 ]; afirmar D04 "falla un paso posterior · el script aborta" $?
! printf '%s' "$salida" | grep -q "Validación sobre la copia completada"
afirmar D04-fin "falla un paso posterior · NO se declara éxito" $?

# Ejecutar desde otro directorio no rompe ninguna ruta.
: > "$TESTIGO"
( cd / && PSQL_SALIDA="SELLO-OK" ejecutar "$RUNNER" "postgresql://localhost:5432/copia" --dry-run >/dev/null 2>&1 )
afirmar D05 "ejecutado desde otro directorio · las rutas siguen bien" $?

echo
echo "── E · Privacidad ──"
RAIZ="$(cd "$AQUI/../../.." && pwd)"

# Se excluye ESTE fichero: lleva URLs de mentira a propósito, y si no se
# excluyera el grep se encontraría a sí mismo.
ENVIADOS=$(find "$RAIZ/supabase/fase2" -type f ! -path '*/pruebas/*')

! grep -lE "eyJ[A-Za-z0-9_-]{20,}" $ENVIADOS >/dev/null 2>&1
afirmar E01 "sin tokens JWT en los archivos que se publican" $?

! grep -lE "postgres(ql)?://[^ '\"]*:[^ '\"]*@" $ENVIADOS >/dev/null 2>&1
afirmar E02 "sin cadenas de conexión con credenciales" $?

! grep -lE "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.(com|es|net|org)" $ENVIADOS >/dev/null 2>&1
afirmar E03 "sin correos reales" $?

# Y en el propio banco, las credenciales solo pueden ser el marcador 'u:p'.
! grep -oE "postgres(ql)?://[^ '\"]*@" "$AQUI/probar-guardas.sh" | grep -qv "://u:p@"
afirmar E04 "las URLs del banco solo llevan el marcador de mentira u:p" $?

# La referencia del proyecto solo puede estar en la guarda y en este banco.
[ "$(grep -rl 'cmkzcvfjgrgxwqjimtxa' "$RAIZ/supabase/fase2" | wc -l)" -eq 2 ]
afirmar E05 "la referencia del proyecto solo aparece en la guarda y en su prueba" $?

echo
echo "════ $((total - fallos))/$total aserciones superadas ════"
[ "$fallos" -eq 0 ] || { echo "FALLOS: $fallos"; exit 1; }
