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

## 3. Lo que hace falta y AHORA MISMO NO HAY

En la máquina donde se está trabajando **no hay ninguna de las herramientas
necesarias**, y no se pueden instalar:

| Herramienta | Estado |
|---|---|
| `psql`, `pg_dump`, `pg_restore` | **no instalados** |
| Supabase CLI | **no instalada** |
| Docker / Podman | **no instalados** |
| `sudo` sin contraseña | **no disponible** — no se pueden instalar |
| MCP de Supabase | requiere autenticación interactiva; sesión no interactiva |

**Consecuencia: el Subtrabajo 2 no se puede ejecutar desde aquí.** Lo tiene que
lanzar Dani en una máquina con PostgreSQL 15 y `pg_dump`, o con Docker.

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

**Producción es de solo lectura en todo este paso.** `pg_dump` no escribe nada.

```bash
# 1 · Volcado completo. La URL está en Supabase → Project settings → Database.
#     NO la pegues en ningún chat ni la metas en un archivo versionado.
export URL_PRODUCCION='...'          # solo en la terminal, no en el historial
pg_dump "$URL_PRODUCCION" --no-owner --no-privileges -Fc -f copia-produccion.dump

# 2 · Una base local y aislada
createdb copia_validacion
pg_restore --no-owner --no-privileges -d copia_validacion copia-produccion.dump

export URL_COPIA='postgresql://localhost:5432/copia_validacion'
```

Con Docker, en vez de `createdb`:

```bash
docker run -d --name copia-validacion -e POSTGRES_PASSWORD=... -p 5433:5432 postgres:15
# y la URL apunta a localhost:5433
```

> `pg_dump` de Supabase puede no traer el esquema `auth` completo según los
> permisos del rol. Si `auth.users` no llega, hay que volcarlo aparte con
> `--schema auth`, o reconstruir un sustituto como el de
> `supabase/pruebas/00_stub_supabase.sql`. **Anotarlo si ocurre**: cambia lo que
> la validación puede demostrar sobre el trigger de alta.

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

Al terminar:

```bash
dropdb copia_validacion                 # o: docker rm -f copia-validacion
shred -u copia-produccion.dump          # si no se conserva
```

Si se conserva, que sea **cifrada**, fuera de cualquier carpeta sincronizada, y
con una fecha de borrado decidida.

## 10. Lo que tiene que decidir o hacer Dani

1. **Dónde se ejecuta**: una máquina con PostgreSQL 15 y `pg_dump`, o con
   Docker. Aquí no hay ninguna de las dos cosas.
2. **Si se anonimiza** la copia. Recomendado si va a durar más de una sesión.
3. **Si estos archivos se suben** al repositorio. Están en la rama local
   `fase-2/validacion-copia`, **sin empujar**.
4. **Si la guarda debe integrarse** en `supabase/aplicar-migraciones.sh`. Ver
   §11.

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
