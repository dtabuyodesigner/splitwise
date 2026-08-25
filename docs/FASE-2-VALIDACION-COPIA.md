# Fase 2 · Validar las migraciones sobre una copia real

> **Subtrabajo 1: preparación. Nada de esto se ha ejecutado.**
> Producción es de solo lectura. No se ha aplicado ninguna migración, no se ha
> creado ninguna copia y no se ha accedido a Supabase.

## 1. Por qué hace falta

El CI valida las migraciones contra una **reconstrucción** del inventario, no
contra los datos reales. Eso demuestra que el SQL compila y que las políticas se
comportan como dicen; **no** demuestra que la migración funcione sobre los datos
que ya existen. Solo aparecen con datos reales: un `client_id` duplicado, una
fila huérfana, un volumen que hace lenta una consulta, o una diferencia entre el
esquema real y el que reconstruimos.

## 2. Estrategia elegida: volcado y restauración en un PostgreSQL aislado

Se han considerado las tres opciones:

| Opción | Veredicto |
|---|---|
| **Supabase branching / staging** | **Descartada por ahora.** Crear una rama es una **escritura** sobre el proyecto, y este subtrabajo es de solo lectura. Además depende del plan contratado, que no se ha comprobado —haría falta entrar al panel—. |
| **`pg_dump` + restauración en PostgreSQL aislado** | **Elegida.** La única interacción con producción es una **lectura** (`pg_dump`). La copia vive en una base que no puede confundirse con producción. Sin coste, sin contratar nada, y con el mismo PostgreSQL 15 que usa el CI, así que los resultados son comparables. |
| Otra copia gestionada por Supabase | Descartada por lo mismo que la primera: implica escritura o contratación. |

**La base de destino debe estar fuera de `*.supabase.co`.** La guarda lo impone.

## 3. Entorno real, y las versiones que importan

La copia ya existe. El entorno que la sostiene:

| | |
|---|---|
| **Producción** | **PostgreSQL 17** — no 15, como se supuso al principio |
| Copia local | PostgreSQL 17, clúster `main`, socket `/var/run/postgresql`, puerto **5433** |
| Base | `splitwise_validacion_fase2` |
| CI | PostgreSQL 15 |

**La restauración tiene que hacerse con PostgreSQL 17.** No es una preferencia:
el volcado de un servidor 17 contiene el privilegio `MAINTAIN`, que no existe en
15, y `pg_restore` de 15 no sabe qué hacer con él. Volcar con el cliente 17 y
restaurar en un servidor 15 falla.

**Queda una diferencia real de versión**: el CI valida las migraciones sobre
PostgreSQL 15 y producción es 17. La validación sobre la copia es precisamente
lo que cierra ese hueco, porque la copia sí es 17.

## 4. Riesgos, y qué los contiene

| Riesgo | Contención |
|---|---|
| Apuntar sin querer a producción | La guarda comprueba **dos cosas independientes**: que la cadena no contiene la referencia del proyecto real ni un host de Supabase, y que la base lleva la marca `public.copia_de_validacion`. Sin las dos, no se ejecuta nada |
| El volcado contiene datos personales | Sale de Supabase y vive en un disco. Ver §6: anonimización opcional, cifrado y borrado |
| Romper la aplicación de viajes | La fotografía captura sus columnas, restricciones, índices, políticas, triggers, funciones, privilegios, Realtime y número de filas; la comparación falla ante cualquier diferencia |
| Perder datos históricos | La comparación exige que los recuentos de perfiles, grupos, gastos y liquidaciones sean idénticos antes y después |
| Que la copia se quede por ahí | §8: borrado, y qué hacer si se conserva |
| Que el volcado no refleje ya producción | Anotar la hora del volcado. Si pasan días, repetirlo antes de dar la validación por buena |

## 5. Cómo obtener la copia — **lo hace Dani**

**Producción es de solo lectura en todo este paso.** `pg_dump` abre su
transacción como `READ ONLY`, y además la conexión lleva
`PGOPTIONS='-c default_transaction_read_only=on'`, de modo que cualquier
escritura fallaría con error en vez de ejecutarse. Esa protección **no se
retira hasta que el volcado ha terminado bien**, y no hay ningún reintento sin
ella: si una consulta protegida falla, se aborta.

No hace falta crear ningún rol de solo lectura en producción — hacerlo sería
una escritura.

```bash
# 1 · La URL, sin eco y sin pasar por el historial
printf 'URL de produccion: ' >&2
stty -echo; IFS= read -r URL_ORIGEN_SOLO_LECTURA; stty echo; echo >&2
export URL_ORIGEN_SOLO_LECTURA
export PGOPTIONS='-c default_transaction_read_only=on'

# 2 · Volcado con el cliente de la MISMA versión mayor que produccion (17)
/usr/lib/postgresql/17/bin/pg_dump "$URL_ORIGEN_SOLO_LECTURA" \
    -Fc --schema=public --schema=auth -f "$DIR/produccion.dump"

unset PGOPTIONS URL_ORIGEN_SOLO_LECTURA   # produccion no se vuelve a tocar

# 3 · La base local: la crea el rol `postgres`, no el usuario habitual
sudo -u postgres createdb -p 5433 -O "$(id -un)" splitwise_validacion_fase2

# 4 · El `public` vacío de la base nueva estorba: el volcado trae el suyo
sudo -u postgres psql -p 5433 -d splitwise_validacion_fase2 -c 'drop schema public'

# 5 · Restaurar con pg_restore 17, y recoger su código SIN que lo intercepte
#     un `trap ERR`: por eso va dentro de un `if`, no suelto
if /usr/lib/postgresql/17/bin/pg_restore -d "$URL_COPIA_LOCAL" --no-owner \
       "$DIR/produccion.dump" > "$DIR/restore.log" 2>&1
then CODIGO=0; else CODIGO=$?; fi
```

Detalles que costaron un intento fallido cada uno, y que hay que respetar:

- **El clúster 17 tiene que existir.** Si `pg_lsclusters` no lo encuentra, el
  procedimiento **aborta**: seguir con un puerto vacío da una URL que no conecta
  y errores que no dicen nada.
- **La base la crea `postgres`**, no el usuario habitual, que no tiene
  `CREATEDB`. El usuario habitual queda como propietario con `-O`, y con eso le
  basta para restaurar.
- **Hay que borrar el `public` vacío** de la base recién creada antes de
  restaurar: si no, choca con el `public` que trae el volcado.
- **`pg_restore` va dentro de un `if`.** Con `set -Eeuo pipefail` y un
  `trap ... ERR`, ejecutarlo suelto hace saltar el trap antes de poder leer su
  código de salida y contar los errores del log.
- **La consulta de roles usa `aclexplode(c.relacl)` a secas.** El
  `coalesce(..., '{}'::aclitem[])` que se puso «por si acaso» convierte los
  permisos por defecto en un array vacío y devuelve menos roles de los que hay.
- **Hay que conceder `authenticated` y `anon` al usuario que se conecta.** En
  Supabase, el rol `postgres` los tiene de serie; en la copia son roles vacíos
  recién creados y nadie pertenece a ellos. Sin la concesión,
  `94_alta_de_usuario.sql` muere en `set local role authenticated` y **la prueba
  del tercero autenticado no llega a ejecutarse**: el resto sale verde y la
  comprobación que de verdad importa se queda sin correr.

  ```sql
  set role postgres;                 -- el usuario de la copia es miembro suyo
  grant authenticated to <usuario>;
  grant anon          to <usuario>;
  reset role;
  ```

  No cambia datos, ni políticas, ni esquema. Es la misma concesión que hace
  `00_stub_supabase.sql` en el CI.

> **Lo que el volcado por esquemas NO trae**: `pg_dump` con `--schema` no
> incluye ni las extensiones ni las **publicaciones**. La copia se restaura sin
> `supabase_realtime`, así que **hay que reconstruirla antes de validar** —si no,
> `0005` la crea de cero y la validación no demuestra nada sobre Realtime. La
> pertenencia real se lee del catálogo de producción durante el volcado y se
> guarda en `realtime.txt`:
>
> ```sql
> create publication supabase_realtime;
> alter publication supabase_realtime add table public.expenses;
> alter publication supabase_realtime add table public.groups;
> alter publication supabase_realtime add table public.settlements;
> ```
>
> Ninguna tabla de viajes pertenecía a esa publicación, y ninguna debe entrar.
>
> `supabase_realtime_messages_publication` **no se reconstruye**: es del esquema
> `realtime`, que no está en esta copia ni lo tocan las migraciones de Splitwise.
> Queda como **frontera externa no validada**.

## 6. Proteger los datos de la copia

En cuanto el volcado sale de Supabase, es un fichero con datos personales.

```bash
# Marca la copia. Sin esto, la guarda no deja ejecutar nada.
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/fase2/10_marcar_copia.sql

# Opcional pero recomendado si la copia va a durar más de una sesión:
psql "$URL_COPIA" -v ON_ERROR_STOP=1 -f supabase/fase2/40_anonimizar.sql
```

La anonimización **borra** correos, metadatos de `auth`, nombres visibles,
conceptos de gastos y notas. **Conserva** —y esto es deliberado, porque sin ello
la validación no demostraría nada—: los UUID y las relaciones, `client_id`,
`profiles.color` (el backfill identifica a cada persona por su color), los
**nombres de los tres grupos** (el backfill exige exactamente esos) y las fechas
e importes (las restricciones `CHECK`).

El fichero `.dump` nunca se versiona. Cífralo si va a quedarse en disco:

```bash
gpg -c copia-produccion.dump && shred -u copia-produccion.dump
```

## 7. Guion del Subtrabajo 2 — **preparado, sin ejecutar**

```bash
supabase/fase2/validar-en-copia.sh "$URL_COPIA" --dry-run   # solo la guarda
supabase/fase2/validar-en-copia.sh "$URL_COPIA"             # la validación entera
```

Hace, en este orden:

| Paso | Qué |
|---|---|
| 0 | **La guarda.** Si la conexión huele a producción o falta la marca, aborta sin ejecutar SQL |
| 1 | Fotografía **antes** (`20_foto.sql`) |
| 2 | `supabase/aplicar-migraciones.sh` — el mismo procedimiento que producción, con `0002`+`0002b` atómicas |
| 3 | Fotografía **después** |
| 4 | Comparación (`30_comparar.sql`), 7 bloques de aserciones |
| 5 | Comprobaciones de esquema (`99_comprobaciones.sql`) |
| 6 | Alta de usuario y aislamiento de un tercero (`94_alta_de_usuario.sql`) |

Lo que **no** cubre el script y hay que hacer a mano: el **recorrido
autenticado** desde la aplicación apuntando a la copia, y la **prueba de
restauración** (§9).

## 8. Qué se comprueba, antes y después

`20_foto.sql` guarda recuentos y metadatos —**ni correos, ni UUID, ni
conceptos, ni notas, ni importes individuales**— y `30_comparar.sql` exige:

| # | Comprobación |
|---|---|
| C1 | La aplicación de **viajes** es idéntica: columnas, restricciones, índices, políticas, triggers, funciones, privilegios, Realtime y número de filas |
| C2 | Mismos recuentos de perfiles, grupos, gastos, liquidaciones y cuentas |
| C3 | Los grupos conservan nombre y número de movimientos |
| C4 | `group_members` **no existía** antes; después: 6 membresías, y los 3 grupos con 2 miembros y 2 propietarios |
| C5 | Todo `paid_by`, `from_user` y `to_user` pertenece a su grupo |
| C6 | Ninguna política anterior ha sobrevivido, y ninguna usa `true` |
| C7 | Sigue habiendo un único mecanismo de alta de perfiles |

Además, la fotografía previa registra los duplicados de `client_id` y las filas
huérfanas: el último inventario dio **cero** en todo, y si la copia dijera otra
cosa habría que parar antes de migrar.

Si la copia coincide con el último inventario, la fotografía previa debe decir:
**2 perfiles, 3 grupos (Casa, Slovenia y Bierzo & Asturias), 53 gastos, 1
liquidación y `group_members` ausente.**

## 9. Marcha atrás y destrucción de la copia

La copia es desechable: la marcha atrás es **volver a restaurar el volcado**.

```bash
dropdb copia_validacion && createdb copia_validacion
pg_restore --no-owner --no-privileges -d copia_validacion copia-produccion.dump
```

Conviene probarlo una vez dentro del Subtrabajo 2: demuestra que el volcado
sirve de verdad para restaurar, que es justo lo que hará falta si algo sale mal
en producción.

Al terminar —y **solo** después de conservar cifrado el último respaldo y
comprobar que se descifra de verdad, no solo que `gpg --list-packets` lo lee—:

```bash
# El destino cifrado va FUERA del patrón que borra el glob de abajo.
DESTINO="$HOME/.splitwise-respaldos-cifrados"; mkdir -p "$DESTINO"; chmod 700 "$DESTINO"
gpg -c --output "$DESTINO/produccion-AAAAMMDD-hhmm.dump.gpg" "$RESPALDO"
gpg --output /dev/null --decrypt "$DESTINO/…​.gpg"   # si esto falla, NO borres nada

sudo -u postgres dropdb -p 5433 splitwise_validacion_fase2
sudo -u postgres dropdb -p 5432 splitwise_validacion_fase2
shred -u "$RESPALDO"
rm -rf ~/.splitwise-fase2-*/
```

`gpg --list-packets` **no vale como verificación**: sobre un fichero cifrado y
válido, sin la contraseña, devuelve código 2, y sobre uno corrupto tampoco
distingue nada. El único que separa bueno de malo es el descifrado completo.

## 10. Lo que tiene que decidir o hacer Dani

> **Resuelto.** Este documento describe el procedimiento tal y como se preparó
> y después se ejecutó. La copia se creó y validó, y producción se migró y
> desplegó el 25 de agosto de 2026 — ver [`CIERRE-FASE-2.md`](CIERRE-FASE-2.md).
> Estos archivos están en `main`, y las herramientas (`psql`, `pg_dump` y
> `pg_restore` 17) quedaron instaladas en la máquina de trabajo.

Queda **una sola decisión abierta**: cuándo eliminar las copias locales y los
volcados, y cuánto tiempo conservar cifrado el último respaldo. Ver §9. **No se
ha borrado nada**: espera autorización expresa.

## 11. Sobre integrar la guarda en el ejecutor

`supabase/aplicar-migraciones.sh` está en la historia ya revisada y **no se ha
tocado**. La guarda es un envoltorio aparte.

**Recomendación: no integrarla.** La guarda exige la marca
`public.copia_de_validacion`, que producción no tiene ni debe tener. Integrarla
en el ejecutor haría que el ejecutor se negara a funcionar **precisamente en
producción**, que es donde acabará teniendo que correr. Son dos herramientas con
propósitos opuestos y conviene que sigan separadas:

- `aplicar-migraciones.sh` → aplica, en cualquier sitio, con orden y
  transacciones correctas;
- `validar-en-copia.sh` → **solo** contra una copia, y lo comprueba dos veces.
