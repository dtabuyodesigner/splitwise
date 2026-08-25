#!/usr/bin/env bash
# ============================================================
#  GUARDA · impide ejecutar nada contra producción
#
#  Uso:
#      supabase/fase2/guarda-no-produccion.sh "$URL_COPIA"
#
#  Devuelve 0 solo si la conexión NO es producción. Cualquier duda → error.
#
#  Dos comprobaciones INDEPENDIENTES, y las dos tienen que pasar:
#
#    1. La cadena de conexión no contiene la referencia del proyecto real.
#       Se comprueba ANTES de conectar, así que ni siquiera se abre sesión
#       contra producción.
#
#    2. La base de destino tiene la marca `public.copia_de_validacion`, que
#       crea el paso de restauración. Producción NO la tiene y no se le va a
#       poner. Esto es lo que hace que la guarda no dependa de que alguien
#       lea bien una URL: aunque la cadena estuviera camuflada, sin la marca
#       no se ejecuta nada.
#
#  Esta guarda NUNCA imprime la cadena de conexión.
# ============================================================
set -euo pipefail

# Referencia del proyecto de producción. Es un identificador público (aparece
# en la URL de la API), no un secreto.
readonly PROYECTO_PRODUCCION="cmkzcvfjgrgxwqjimtxa"

# Sello que tiene que llevar la marca. Una tabla con el nombre correcto pero
# otro contenido NO vale: podría venir de cualquier sitio.
readonly SELLO_ESPERADO="COPIA-DE-VALIDACION-FASE-2"

URL="${1:-}"

if [ -z "$URL" ]; then
    echo "guarda: falta la URL de la copia" >&2
    echo "Uso: $0 <url-de-la-COPIA>" >&2
    exit 64
fi

# ── 1 · La cadena no puede apuntar al proyecto real ──────────
if printf '%s' "$URL" | grep -qiF "$PROYECTO_PRODUCCION"; then
    echo "GUARDA: la conexión apunta al proyecto de PRODUCCIÓN. Abortado." >&2
    echo "        No se ha abierto ninguna sesión ni ejecutado ningún SQL." >&2
    exit 1
fi

# Red adicional: cualquier host de Supabase gestionado. Una copia de
# validación debería vivir en un PostgreSQL aislado, no en Supabase.
# Si algún día se valida en un proyecto de staging de Supabase, hay que
# quitar esta comprobación A PROPÓSITO y dejarlo escrito.
if printf '%s' "$URL" | grep -qiE '\.supabase\.(co|com)'; then
    echo "GUARDA: la conexión apunta a un host de Supabase gestionado." >&2
    echo "        La copia de validación debe estar en un PostgreSQL aislado." >&2
    echo "        Si esto es deliberado, edita la guarda y déjalo justificado." >&2
    exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "guarda: no hay psql instalado; no se puede comprobar la marca" >&2
    exit 69
fi

# ── 2 · La base tiene que llevar la marca de copia ───────────
# Si psql falla por lo que sea —no conecta, no existe la tabla, permisos—,
# la variable se queda en SIN-MARCA y se aborta. Fallar en seguro.
MARCA=$(psql "$URL" -X -A -t -v ON_ERROR_STOP=1 -c \
    "select coalesce((select 'SELLO-OK' from public.copia_de_validacion
                       where sello = '$SELLO_ESPERADO' limit 1), 'SELLO-AUSENTE')" \
    2>/dev/null || echo "SIN-MARCA")

MARCA=$(printf '%s' "$MARCA" | tr -d '[:space:]')

if [ "$MARCA" != "SELLO-OK" ]; then
    echo "GUARDA: la base de destino no lleva el sello de copia de validación." >&2
    echo "        Esperado: una fila con sello = $SELLO_ESPERADO" >&2
    echo "        Encontrado: ${MARCA:-(nada)}" >&2
    echo >&2
    echo "        Si es una copia recién restaurada, aplícale primero:" >&2
    echo "          psql \"\$URL_COPIA\" -f supabase/fase2/10_marcar_copia.sql" >&2
    echo "        Si NO es una copia, no sigas." >&2
    exit 1
fi

echo "guarda: ok · la conexión no es producción y lleva la marca de copia"
