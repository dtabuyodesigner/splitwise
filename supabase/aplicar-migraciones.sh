#!/usr/bin/env bash
# ============================================================
#  Aplica las migraciones en el orden y con los límites
#  transaccionales correctos.
#
#  Uso:
#      supabase/aplicar-migraciones.sh "postgresql://..."
#      supabase/aplicar-migraciones.sh "$URL" --dry-run
#
#  Existe para que nadie tenga que acordarse de combinar archivos a mano.
#  Lo importante que hace por ti:
#
#    · 0002 y 0002b van en UNA SOLA transacción. Si el backfill aborta,
#      `group_members` no llega a existir. Aplicarlos por separado deja la
#      tabla creada y vacía, y en ese estado la aplicación no enseña ningún
#      grupo.
#    · cada migración se aplica con --single-transaction, así que ninguna
#      puede quedarse a medias.
#    · el orden es explícito y no depende del `locale` del sistema: hay
#      configuraciones regionales donde `0002b_` se ordena ANTES que
#      `0002_group_members`.
#
#  NO aplica nada por su cuenta a ninguna base: hay que pasarle la URL.
# ============================================================
set -euo pipefail

URL="${1:-}"
MODO="${2:-}"

if [ -z "$URL" ]; then
    echo "Uso: $0 <url-de-la-base-de-datos> [--dry-run]" >&2
    echo >&2
    echo "La URL está en Supabase → Project settings → Database." >&2
    exit 64
fi

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cada elemento es un paso. El lote de pertenencia es UNO SOLO a propósito.
PASOS=(
    "migrations/0001_baseline_esquema.sql"
    "lotes/pertenencia.sql"
    "migrations/0003_restricciones_indices.sql"
    "migrations/0004_rls.sql"
    "migrations/0005_realtime.sql"
    "migrations/0006_rls_viajes.sql"
    "migrations/0007_traslado_de_saldo.sql"
    "migrations/0008_privilegios_de_funciones.sql"
    "migrations/0009_privilegios_por_defecto.sql"
    "migrations/0010_consentimiento_y_oraculo.sql"
    "migrations/0011_invitaciones.sql"
)

echo "Migraciones a aplicar, en este orden:"
for paso in "${PASOS[@]}"; do
    if [ "$paso" = "lotes/pertenencia.sql" ]; then
        echo "  · $paso   ← 0002 + 0002b, EN UNA SOLA TRANSACCIÓN"
    else
        echo "  · $paso"
    fi
done
echo

if [ "$MODO" = "--dry-run" ]; then
    echo "--dry-run: no se ha ejecutado nada."
    exit 0
fi

echo "Copia de seguridad ANTES de continuar. Ctrl-C para abortar."
echo "  supabase db dump --db-url \"\$URL\" -f respaldo-\$(date +%F-%H%M).sql"
echo
read -r -p "¿Tienes la copia hecha y verificada? Escribe SI para seguir: " respuesta
if [ "$respuesta" != "SI" ]; then
    echo "Abortado."
    exit 1
fi

for paso in "${PASOS[@]}"; do
    echo "── aplicando $paso"
    # --single-transaction: o entra entero o no entra nada.
    psql "$URL" -v ON_ERROR_STOP=1 --single-transaction -f "$AQUI/$paso"
    echo "   ok"
done

echo
echo "Migraciones aplicadas. Comprueba ahora el esquema resultante:"
# Puerta final. PostgreSQL concede EXECUTE a PUBLIC en toda funcion nueva y
# eso no se puede desactivar con `alter default privileges`: si una migracion
# se olvida de su revoke, la funcion queda al alcance del rol anonimo. Esto lo
# caza aqui, antes de dar el despliegue por bueno.
echo
echo "== Comprobando que ninguna funcion ha quedado abierta =="
psql "$URL" -v ON_ERROR_STOP=1 -f "$AQUI/pruebas/106_ninguna_funcion_abierta.sql" \
  || { echo "DESPLIEGUE INCOMPLETO: hay funciones abiertas a PUBLIC o anon." >&2; exit 1; }

echo "  psql \"\$URL\" -v ON_ERROR_STOP=1 -f supabase/pruebas/99_comprobaciones.sql"
