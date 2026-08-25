#!/usr/bin/env bash
# ============================================================
#  SUBTRABAJO 2 · valida las migraciones sobre una COPIA
#
#      supabase/fase2/validar-en-copia.sh "$URL_COPIA"
#      supabase/fase2/validar-en-copia.sh "$URL_COPIA" --dry-run
#
#  NO se ha ejecutado todavía. Este archivo es el guion preparado.
#
#  Lo primero que hace, SIEMPRE, es pasar la guarda: si la conexión huele a
#  producción o le falta la marca de copia, aborta sin ejecutar ningún SQL.
#
#  Este script NUNCA imprime la cadena de conexión.
# ============================================================
set -euo pipefail

URL="${1:-}"
MODO="${2:-}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"

if [ -z "$URL" ]; then
    echo "Uso: $0 <url-de-la-COPIA> [--dry-run]" >&2
    exit 64
fi

paso() { echo; echo "══ $* ══"; }

# ── 0 · La guarda, antes que nada ────────────────────────────
paso "0 · Comprobando que la conexión NO es producción"
"$AQUI/guarda-no-produccion.sh" "$URL"

if [ "$MODO" = "--dry-run" ]; then
    echo
    echo "--dry-run: la guarda ha pasado. No se ejecuta nada más."
    exit 0
fi

# ── 1 · Fotografía previa ────────────────────────────────────
paso "1 · Fotografía ANTES de migrar"
psql "$URL" -v ON_ERROR_STOP=1 -v momento=antes -f "$AQUI/20_foto.sql" </dev/null

# ── 2 · Las migraciones, con el mismo procedimiento que producción ──
paso "2 · Aplicando las migraciones (aplicar-migraciones.sh)"
# `aplicar-migraciones.sh` pide confirmación de que hay copia de seguridad.
# Esa pregunta existe para producción; aquí la respondemos por él y dejamos
# escrito por qué: esto YA es una copia desechable —la guarda lo ha
# comprobado dos veces—, y su "copia de seguridad" es el propio volcado, que
# se vuelve a restaurar en un minuto. Sin esto, la validación se quedaría
# esperando una tecla para siempre.
#
# `</dev/null` en el resto de pasos para que ninguno pueda colgarse pidiendo
# entrada por teclado.
echo "SI" | "$RAIZ/supabase/aplicar-migraciones.sh" "$URL"

# ── 3 · Fotografía posterior ─────────────────────────────────
paso "3 · Fotografía DESPUÉS de migrar"
psql "$URL" -v ON_ERROR_STOP=1 -v momento=despues -f "$AQUI/20_foto.sql" </dev/null

# ── 4 · Comparación ──────────────────────────────────────────
paso "4 · Comparando antes y después"
psql "$URL" -v ON_ERROR_STOP=1 -f "$AQUI/30_comparar.sql" </dev/null

# ── 5 · Las comprobaciones de esquema y los ataques ──────────
paso "5 · Comprobaciones de esquema"
psql "$URL" -v ON_ERROR_STOP=1 -f "$RAIZ/supabase/pruebas/99_comprobaciones.sql" </dev/null

paso "6 · Alta de usuario y aislamiento de un tercero"
psql "$URL" -v ON_ERROR_STOP=1 -f "$RAIZ/supabase/pruebas/94_alta_de_usuario.sql" </dev/null

echo
echo "Validación sobre la copia completada."
echo "Queda por hacer a mano: el recorrido autenticado desde la aplicación."
