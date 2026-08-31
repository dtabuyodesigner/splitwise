#!/usr/bin/env bash
# ============================================================
# Dos personas aceptan LA MISMA invitación de un solo uso, a la vez.
#
# Esto no se puede probar desde un único psql: hacen falta dos transacciones
# de verdad, simultáneas. Por eso vive en un guion y no en un .sql.
#
# Lo que se exige, ronda tras ronda:
#   · exactamente UNA aceptación y UNA «agotada»;
#   · `usos` acaba en 1, nunca en 2;
#   · entra UNA sola persona en el grupo.
#
# Sin el `for update` de `aceptar_invitacion` las dos leerían `usos = 0` y las
# dos entrarían: es justo lo que comprueba esta prueba.
#
# Usa la conexión de las variables de libpq (PGHOST, PGPORT, PGUSER,
# PGDATABASE), igual que el resto del CI. Crea sus propias filas y las borra
# al terminar; no toca nada más.
# ============================================================
set -Eeuo pipefail

RONDAS="${RONDAS:-15}"
psqlq() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

G='fbbb0000-0000-0000-0000-0000000000f1'
U1='fbbb0000-0000-0000-0000-0000000000a1'
U2='fbbb0000-0000-0000-0000-0000000000a2'
U3='fbbb0000-0000-0000-0000-0000000000a3'

limpiar() {
    psqlq >/dev/null 2>&1 <<SQL || true
delete from public.groups where id = '$G';
delete from public.profiles where id in ('$U1','$U2','$U3');
delete from auth.users where id in ('$U1','$U2','$U3');
SQL
}
trap limpiar EXIT

limpiar
psqlq >/dev/null <<SQL
insert into auth.users (id, email) values
  ('$U1','concurrente1@prueba.test'),
  ('$U2','concurrente2@prueba.test'),
  ('$U3','concurrente3@prueba.test');
insert into public.groups (id, name, created_by) values ('$G','Carrera','$U1');
SQL

fallos=0
for ronda in $(seq 1 "$RONDAS"); do
    # Estado limpio: solo el propietario dentro, y una invitación de un uso.
    psqlq >/dev/null <<SQL
delete from public.group_members where group_id = '$G' and user_id in ('$U2','$U3');
delete from public.group_invitations where group_id = '$G';
SQL
    TOKEN=$(psqlq -tAc "
        set local role authenticated;
        set local request.jwt.claims = '{\"sub\":\"$U1\"}';
        select public.crear_invitacion('$G', 7, 1);")

    # Las dos a la vez. El pg_sleep dentro de la transacción garantiza que se
    # solapan de verdad en vez de ejecutarse una detrás de otra.
    correr() {
        psql -X -tAq -c "
            begin;
            set local role authenticated;
            set local request.jwt.claims = '{\"sub\":\"$1\"}';
            select pg_sleep(0.25);
            select resultado from public.aceptar_invitacion('$TOKEN');
            commit;" 2>/dev/null | grep -E '^(aceptada|agotada|ya_eras_miembro|revocada|caducada|desconocida)$' || echo error
    }
    correr "$U2" > /tmp/carrera-a.$$ &
    p1=$!
    correr "$U3" > /tmp/carrera-b.$$ &
    p2=$!
    wait $p1 $p2

    r1=$(cat /tmp/carrera-a.$$); r2=$(cat /tmp/carrera-b.$$)
    rm -f /tmp/carrera-a.$$ /tmp/carrera-b.$$

    aceptadas=$(printf '%s\n%s\n' "$r1" "$r2" | grep -c '^aceptada$' || true)
    usos=$(psqlq -tAc "select usos from public.group_invitations where group_id = '$G'")
    dentro=$(psqlq -tAc "select count(*) from public.group_members
                          where group_id = '$G' and user_id in ('$U2','$U3')")

    if [ "$aceptadas" -ne 1 ] || [ "$usos" -ne 1 ] || [ "$dentro" -ne 1 ]; then
        echo "  ronda $ronda FALLA · resultados=[$r1,$r2] aceptadas=$aceptadas usos=$usos dentro=$dentro"
        fallos=$((fallos + 1))
    fi
done

if [ "$fallos" -ne 0 ]; then
    echo "CONCURRENCIA INCORRECTA: $fallos de $RONDAS rondas han fallado" >&2
    exit 1
fi
echo "[C01] ok — $RONDAS rondas de aceptación simultánea: siempre una sola entrada y usos=1"
