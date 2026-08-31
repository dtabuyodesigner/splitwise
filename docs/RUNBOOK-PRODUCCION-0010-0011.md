# Runbook de produccion para 0010 y 0011

**Estado:** preparado, no ejecutado.
**Fecha:** 31 de agosto de 2026.
**Alcance:** aplicar en produccion las migraciones `0010_consentimiento_y_oraculo.sql` y `0011_invitaciones.sql`, que ya estan fusionadas en `main`.

Este documento no autoriza ejecutar nada. La decision de tocar produccion es de Dani.

---

## 1. Estado de partida

- `main` contiene F0/F1 desde el PR #6 y el cierre documental posterior.
- El cierre documental posterior a F0/F1 esta en `a4af34dca74952ae6f14f3ccd21aba01796d3343`; este runbook se prepara encima de ese estado.
- Produccion ya tenia aplicadas y validadas las migraciones hasta `0009`.
- Produccion **no** tiene aplicadas `0010` ni `0011`.
- No hay cambios de frontend: `VERSION_APP` sigue en `v17`.
- No hay UI para invitaciones todavia: `0011` instala solo el servidor.

Implicacion practica: Alba puede seguir usando la app actual sin hacer nada. Las invitaciones por enlace no son visibles hasta F2.

---

## 2. Que cambian 0010 y 0011

`0010`:

- Retira la politica `miembros_invitar`, que permitia meter a terceros en un grupo.
- Crea `miembros_apuntarme_a_mi_grupo`: solo permite que una persona se apunte a si misma en un grupo creado por ella.
- Cambia `group_members` a `grant update (role)`, para impedir reescribir `user_id`.
- Cambia `groups` a `grant update (name)`, para impedir reescribir `created_by`.
- Ajusta `es_miembro()` y `es_owner()` para que no respondan como oraculo sobre terceros ajenos.

`0011`:

- Crea `group_invitations`.
- Guarda solo `token_hash`, nunca el token en claro.
- Instala `crear_invitacion()`, `ver_invitacion()`, `aceptar_invitacion()` y `revocar_invitacion()`.
- No concede nada a `anon`.
- Bloquea la aceptacion con `FOR UPDATE` para enlaces de uso limitado.

---

## 3. Criterio de parada

Abortar si ocurre cualquiera de estos puntos:

1. El arbol local no esta limpio salvo ficheros scratch untracked.
2. `origin/main` no apunta al SHA esperado o hay commits nuevos no revisados.
3. No hay copia reciente de produccion.
4. La copia no lleva la marca `public.copia_de_validacion`.
5. La guarda `supabase/fase2/guarda-no-produccion.sh` no pasa.
6. La validacion especifica de `0010`/`0011` en copia falla.
7. La huella de datos antes/despues cambia en recuentos, saldos o contenido historico.
8. `106_ninguna_funcion_abierta.sql` detecta funciones abiertas a `PUBLIC` o `anon`.
9. La app local contra la copia no permite las operaciones basicas actuales.
10. Dani no confirma expresamente que se puede tocar produccion.

Si se aborta, no se intenta "arreglar en caliente" sobre produccion. Se vuelve al repo, se corrige con PR y se repite la validacion.

---

## 4. Preparacion local

Comprobar que el repo esta en el estado esperado:

```bash
cd /home/danito73/Documentos/APP_SPLITWISE/splitwise
git status --short --branch
git fetch origin main
git log --oneline --decorate -5 origin/main
git diff --check origin/main
npm test
npm run verificar
```

Resultado esperado:

- `main` y `origin/main` contienen este runbook y estan sincronizados.
- Sin cambios locales versionados.
- Puede existir `PROMPT-CLAUDE-COMMIT-INVITACIONES.md` como untracked; no se sube.
- `npm test` y `npm run verificar` en verde.

---

## 5. Crear copia de produccion

Esto lo hace Dani porque requiere credenciales de Supabase y puede contener datos personales.

Produccion se toca solo en lectura. La URL no se pega en chats ni documentos.

```bash
mkdir -p "$HOME/.splitwise-validacion-0010-0011"
chmod 700 "$HOME/.splitwise-validacion-0010-0011"
cd "$HOME/.splitwise-validacion-0010-0011"

printf 'URL de produccion: ' >&2
stty -echo
IFS= read -r URL_PRODUCCION
stty echo
echo >&2

export PGOPTIONS='-c default_transaction_read_only=on'
/usr/lib/postgresql/17/bin/pg_dump "$URL_PRODUCCION" -Fc --schema=public --schema=auth -f produccion-antes-0010-0011.dump
unset PGOPTIONS URL_PRODUCCION
```

Comprobar que el volcado existe y no esta vacio:

```bash
ls -lh produccion-antes-0010-0011.dump
/usr/lib/postgresql/17/bin/pg_restore -l produccion-antes-0010-0011.dump >/tmp/splitwise-restore-list.txt
wc -l /tmp/splitwise-restore-list.txt
```

---

## 6. Restaurar copia aislada

La copia debe vivir fuera de Supabase gestionado. El procedimiento usado en fase 2 fue PostgreSQL 17 local en puerto `5433`.

```bash
sudo -u postgres createdb -p 5433 -O "$(id -un)" splitwise_validacion_0010_0011
sudo -u postgres psql -p 5433 -d splitwise_validacion_0010_0011 -c 'drop schema public'

export URL_COPIA="postgresql://$(id -un)@/splitwise_validacion_0010_0011?host=/var/run/postgresql&port=5433"
export PGHOST=/var/run/postgresql
export PGPORT=5433
export PGDATABASE=splitwise_validacion_0010_0011
export PGUSER="$(id -un)"

/usr/lib/postgresql/17/bin/pg_restore -d "$URL_COPIA" --no-owner produccion-antes-0010-0011.dump > restore.log 2>&1
```

Si `pg_restore` devuelve avisos, revisarlos. No seguir con errores de restauracion no entendidos.

Conceder roles de prueba al usuario local, como hace Supabase con `postgres`:

```bash
sudo -u postgres psql -p 5433 -d splitwise_validacion_0010_0011 <<SQL
grant authenticated to "$(id -un)";
grant anon to "$(id -un)";
SQL
```

Reconstruir `supabase_realtime` si el volcado por esquemas no trajo publicaciones. No meter tablas de viajes si no estaban publicadas.

---

## 7. Marcar y proteger la copia

Desde el repo:

```bash
cd /home/danito73/Documentos/APP_SPLITWISE/splitwise
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/fase2/10_marcar_copia.sql
supabase/fase2/guarda-no-produccion.sh "$URL_COPIA"
```

Opcional si la copia va a vivir mas de una sesion:

```bash
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/fase2/40_anonimizar.sql
```

Si se anonimiza, hacerlo antes de validar y dejarlo anotado.

---

## 8. Huella previa especifica de 0010/0011

En la copia ya restaurada, antes de migrar:

```bash
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/112_huella_de_datos.sql > /tmp/splitwise-huella-antes-0010-0011.txt
cat /tmp/splitwise-huella-antes-0010-0011.txt
```

Guardar esa salida. La comparacion posterior debe ser identica.

---

## 9. Validacion completa en copia

No usar `supabase/fase2/validar-en-copia.sh` para este cierre. Ese script
pertenece a la validacion historica de `0001` a `0009` y espera que
`group_members` no exista antes de migrar. En este punto produccion ya esta en
`0009`, asi que la copia ya debe traer `group_members`.

Primero ejecutar la guarda:

```bash
supabase/fase2/guarda-no-produccion.sh "$URL_COPIA"
```

Aplicar solo `0010` y `0011` en la copia, en el mismo orden en que se aplicarian
en produccion:

```bash
psql "$URL_COPIA" -v ON_ERROR_STOP=1 --single-transaction -f supabase/migrations/0010_consentimiento_y_oraculo.sql
psql "$URL_COPIA" -v ON_ERROR_STOP=1 --single-transaction -f supabase/migrations/0011_invitaciones.sql
```

Ejecutar las pruebas especificas de F0/F1 y puertas finales:

```bash
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/98_seguridad_dml.sql
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/99_comprobaciones.sql
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/100_invariantes.sql
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/105_privilegios_de_funciones.sql
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/106_ninguna_funcion_abierta.sql
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/110_invitaciones.sql
bash supabase/pruebas/111_aceptaciones_concurrentes.sh
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/pruebas/112_huella_de_datos.sql > /tmp/splitwise-huella-despues-0010-0011.txt
diff -u /tmp/splitwise-huella-antes-0010-0011.txt /tmp/splitwise-huella-despues-0010-0011.txt
```

El `diff` debe salir vacio. Si no sale vacio, abortar.

---

## 10. Recorrido manual contra copia

Apuntar la app local a la copia o revisar desde SQL con usuarios suplantados. Como minimo:

1. Dani ve sus grupos actuales.
2. Alba/Pilar ve sus grupos actuales.
3. Un tercero autenticado sin membresias no ve grupos, gastos ni perfiles ajenos.
4. Renombrar un grupo funciona.
5. Cambiar `groups.created_by` como miembro normal falla.
6. Cambiar `group_members.user_id` como owner falla.
7. Crear invitacion como miembro funciona.
8. Ver invitacion valida como autenticado muestra grupo/invita/caducidad, sin `group_id`.
9. Aceptar invitacion mete al usuario como `member`.
10. Reabrir invitacion siendo ya miembro no incrementa `usos`.
11. Invitacion de un uso con dos aceptaciones simultaneas solo acepta una.

No hace falta que Alba toque nada todavia: no hay UI de invitaciones en produccion.

---

## 11. Aplicacion a produccion

Solo despues de:

- copia creada;
- validacion en copia verde;
- huella antes/despues identica;
- recorrido manual aceptado;
- Dani dice expresamente que se puede tocar produccion.

Primero dry-run:

```bash
supabase/aplicar-migraciones.sh "$URL_PRODUCCION" --dry-run
```

Despues aplicacion real. Aunque el ejecutor enumera todas las migraciones, las
anteriores ya estan en produccion y deben ser idempotentes; el cambio efectivo
esperado es `0010` y `0011`.

```bash
supabase/aplicar-migraciones.sh "$URL_PRODUCCION"
```

El script pedira confirmacion. Escribir `SI` solo si existe copia hecha y verificada.

---

## 12. Verificacion inmediata en produccion

No crear invitaciones reales durante la verificacion salvo que Dani lo decida.

Ejecutar:

```bash
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/pruebas/99_comprobaciones.sql
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/pruebas/100_invariantes.sql
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/pruebas/106_ninguna_funcion_abierta.sql
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/pruebas/112_huella_de_datos.sql
```

Comprobaciones esperadas:

- No hay funciones abiertas a `PUBLIC` ni `anon`.
- `authenticated` no tiene `update` de tabla en `groups` ni `group_members`.
- `authenticated` si tiene `update(name)` en `groups`.
- `authenticated` si tiene `update(role)` en `group_members`.
- `estado_invitacion()` es `STABLE`.
- `group_invitations.token_hash` no es legible para `authenticated`.
- Recuentos y saldos siguen coherentes.

---

## 13. Marcha atras

`0010` y `0011` son cambios de esquema y privilegios, no mueven datos. La marcha atras preferente ante fallo grave es restaurar el backup completo tomado antes.

Medidas de emergencia, solo para recuperar acceso mientras se prepara una correccion:

- Si la app queda en blanco por RLS, desactivar RLS temporalmente en las tablas de Splitwise segun `supabase/README.md` seccion 8.
- Si el problema es una funcion abierta, no seguir usando la app hasta corregir grants y pasar `106_ninguna_funcion_abierta.sql`.
- Si falla la tabla de invitaciones, no usar invitaciones; F2 aun no existe, asi que el frontend actual no depende de ella.

No borrar `group_invitations` en caliente salvo que el diagnostico lo justifique y haya backup.

---

## 14. Lo que requiere Dani

Dani tiene que aportar o decidir:

1. URL de conexion de produccion, introducida localmente y sin pegarla en chat.
2. Confirmacion de que se puede hacer `pg_dump` de produccion.
3. Permiso para crear/restaurar la copia local.
4. Permiso explicito para aplicar a produccion, solo despues de validacion verde.
5. Decision sobre conservar o borrar la rama `funcion/invitaciones`.
6. Decision sobre conservar o borrar `PROMPT-CLAUDE-COMMIT-INVITACIONES.md`.
7. Decision de producto antes de F2: cualquier miembro puede crear invitaciones o solo `owner`.

---

## 15. Estado final esperado

Cuando todo termine correctamente:

- `0010` y `0011` aplicadas a produccion.
- `99`, `100`, `106` verdes en produccion.
- Huella `112` coherente.
- Frontend sigue v17.
- Alba no tiene que instalar ni actualizar nada.
- Invitaciones por enlace siguen sin UI hasta F2.
- `docs/PENDIENTES.md` puede actualizarse para marcar "produccion aplicada" con fecha y evidencia.
