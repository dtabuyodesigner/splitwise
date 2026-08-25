# Informe de auditoría inicial (solo lectura)

- **Repositorio auditado:** https://github.com/dtabuyodesigner/splitwise
- **SHA auditado:** `cbc1e1336065f4184aff2e61c0df06ca22e2d25b` (HEAD de `main`)
- **Alcance:** los 4 archivos del repositorio. No se ha ejecutado ninguna consulta contra Supabase.
- **Fecha:** 2026-08-23

---

## 0. Declaración expresa sobre lo que NO se ha podido verificar

Este informe se basa **únicamente en el código fuente del repositorio**. No se ha inspeccionado
el proyecto Supabase de producción. En concreto, **no se ha podido comprobar**:

1. Si RLS está activado en `profiles`, `groups`, `expenses`, `settlements`.
2. Qué políticas RLS existen, si existen.
3. El esquema real: tipos de columna, claves foráneas, `ON DELETE`, restricciones `CHECK`.
4. Si existe el índice único sobre `client_id` que `upsert(onConflict:'client_id')` necesita.
5. Cuántos usuarios y cuántos grupos hay realmente.
6. Si `handle_new_user` u otro trigger crea la fila de `profiles` al registrarse.
7. La configuración de Auth (si el alta pública está abierta o cerrada).

**Por tanto: este informe no afirma que la aplicación sea insegura.** Afirma que
*el repositorio no contiene ninguna prueba de que sea segura*, que el frontend está escrito
de una forma que solo es correcta bajo supuestos muy concretos, y que esos supuestos no están
documentados ni versionados. Las preguntas concretas necesarias para cerrar esta incertidumbre
están en la sección 7.

---

## 1. Arquitectura actual

```
index.html (138 KB, monolito)
├── <head>      metadatos + iconos data-URI + Google Fonts + 1020 líneas de CSS en línea
├── <body>      pantalla de acceso, pantalla de app, 5 hojas modales
└── <script type="module">   2703 líneas: 100 % de la lógica
                └── import createClient desde cdn.jsdelivr.net (CDN, sin SRI, sin fallback)

manifest.json   iconos únicamente como data URI base64
sw.js           cache-first para recursos, network-first solo para navegación
```

**Modelo de ejecución.** Cliente puro. No hay backend propio: el navegador habla directamente
con PostgREST/Supabase usando la clave `anon` y el JWT del usuario. Toda regla de negocio
—quién puede ver qué, quién puede escribir qué— tiene que vivir necesariamente en RLS.
El repositorio no contiene esas reglas.

**Modelo de datos efectivo (deducido del código).** La aplicación asume **exactamente dos
usuarios en toda la instancia**, no dos usuarios por grupo:

```js
estado.otro = estado.perfiles.find(p => p.id !== estado.yo?.id);   // línea 1652 aprox.
function otroId(id) { return estado.perfiles.find(p => p.id !== id)?.id; }
```

`estado.perfiles` viene de `sb.from('profiles').select('*')` sin filtro. "La otra persona" es
*cualquier* perfil que no seas tú. Los grupos son etiquetas para separar listas de gastos,
no unidades de pertenencia: no hay tabla de membresía y `groups` no tiene owner.

**Flujo de datos.**

```
iniciar() → getSession() → entrarEnLaApp()
                            ├── leerCache()            (localStorage, pinta al instante)
                            ├── refrescar() → cargarTodo()   4 SELECT en paralelo
                            ├── vaciarCola()           reintenta la cola offline
                            └── escucharCambios()      1 canal Realtime, 4 tablas, sin filtro
```

Cualquier evento Realtime en cualquier fila de cualquiera de las 4 tablas dispara
`refrescar()`, que recarga las 4 tablas enteras.

---

## 2. Riesgos confirmados en el código

Confirmado = observable leyendo el repositorio, sin depender de la configuración de Supabase.

### R1 · El frontend no puede aislar grupos, y solo es correcto con 2 usuarios en total — **P0**

`profiles.select('*')` + `find(p => p.id !== yo.id)` significa que:

- Si se registra un **tercer** usuario en la instancia, `estado.otro` pasa a ser
  *el primer perfil que devuelva la consulta que no seas tú*. Cambia de forma no determinista.
- Peor: `calcularSaldo()` reparte cada gasto entre el pagador y `perfiles.find(p => p.id !== g.paid_by)`,
  es decir, **un tercero arbitrario**. Con 3 perfiles, los saldos pasan a ser silenciosamente
  incorrectos, sin ningún error visible.
- El selector de grupo enseña **todos** los grupos que devuelva la consulta. Si RLS no los
  filtra, un usuario ve los grupos de otros.

Este es a la vez un riesgo de **saldos incorrectos** y de **acceso a datos ajenos**.
Su gravedad real depende de RLS (no verificable), pero la parte de "saldo incorrecto con
3 perfiles visibles" es un fallo del cliente independiente de RLS.

### R2 · Cualquier error de escritura se confunde con "estás sin conexión" — **P0**

`guardarGasto()`, línea ~3640:

```js
if (navigator.onLine) {
    const { error } = await sb.from('expenses').insert(fila);
    if (!error) enviado = true;          // ← el error se descarta sin mirarlo
}
if (enviado) { ... } else {
    encolar('expenses', fila);           // ← todo lo demás va a la cola
    recado('Guardado localmente, se enviará con conexión');
}
```

Idéntico en `guardarLiquidacion()`. Consecuencia: un rechazo de RLS (42501), un JWT caducado,
una violación de `CHECK` o de clave foránea producen el mensaje *"Guardado localmente, se
enviará con conexión"* y una tarea en la cola que **nunca podrá sincronizarse**.

`vaciarCola()` agrava el problema: reintenta indefinidamente, sin clasificar el error y sin
límite de intentos. Una tarea envenenada se queda en la cola para siempre, y la barra de
estado dice "N apunte(s) por enviar" indefinidamente. El usuario cree que su gasto está a
salvo cuando no lo está.

### R3 · Cola y caché compartidas entre cuentas — **P0**

Las cinco claves de `localStorage` son globales al navegador:

```js
const CLAVE_CACHE = 'gastos.cache';   const CLAVE_COLA  = 'gastos.cola';
const CLAVE_GRUPO = 'gastos.grupo';   const CLAVE_CORREO= 'gastos.correo';
const CLAVE_VISITA= 'gastos.visita';
```

Y `salir()` solo borra una de ellas:

```js
async function salir() {
    await sb.auth.signOut();
    localStorage.removeItem(CLAVE_CACHE);   // cola, grupo y visita sobreviven
    location.reload();
}
```

Escenario reproducible: A trabaja sin cobertura y deja 3 apuntes en cola → A cierra sesión →
B entra en el mismo dispositivo → `entrarEnLaApp()` llama a `leerCola()` y a `vaciarCola()` →
**los apuntes de A se insertan con la sesión de B**. Con RLS bien puesta serían rechazados
(y, por R2, volverían a la cola en bucle); sin RLS, se insertan.

### R4 · Ediciones y borrados optimistas sin restauración — **P0**

`borrarGasto()`:

```js
estado.gastos = estado.gastos.filter(g => String(g.id) !== String(idGasto));  // ya borrado local
try {
    const { error } = await sb.from('expenses').delete().eq('id', idGasto);
    if (error) throw error;                       // ← no se restaura nada
} catch (error) { mostrarAviso($('avisoGasto'), traducirError(error)); }
```

El gasto desaparece de la pantalla y del saldo aunque el servidor lo rechace. Sigue existiendo
en la base de datos. El mismo patrón está en `guardarGasto()` (rama de edición),
`guardarLiquidacion()` (rama de edición) y `borrarLiquidacion()`. No hay `refrescar()` en la
rama de error, así que la pantalla queda mintiendo hasta la siguiente recarga.

Agravante: en `borrarGasto` la hoja modal **no se cierra** en caso de error, pero
`estado.editando` sigue apuntando a un gasto ya eliminado del array local.

### R5 · Los borrados y ediciones de la cola no comprueban si han surtido efecto — **P0**

```js
const { error } = await sb.from('expenses').update(resto).eq('id', id);
if (error) throw error;
```

PostgREST **no devuelve error** cuando un `UPDATE`/`DELETE` no afecta a ninguna fila (porque
RLS la oculta, o porque el `id` no existe). La tarea se marca como sincronizada con éxito
aunque no haya hecho nada. Pérdida silenciosa de la edición.

### R6 · Editar o borrar offline un apunte que todavía está pendiente pierde el cambio — **P0**

Un apunte creado sin conexión vive en `estado.gastos` con `id = client_id` (un UUID de cliente,
no el `id` del servidor). Si el usuario lo edita antes de que se sincronice:

```js
encolar('expenses_update', { id: estado.editando, ...fila });   // id = client_id
```

La cola queda con dos tareas: el `insert` original (con los valores **antiguos**) y un `update`
sobre un `id` que el servidor no conoce. Al vaciar la cola: el insert mete los valores viejos,
el update no afecta a ninguna fila y —por R5— se da por bueno. **La edición se pierde en silencio.**
Lo mismo con `expenses_delete` sobre un apunte pendiente: se inserta y no se borra.

### R7 · Saldo calculado sobre un conjunto truncado — **P0**

```js
sb.from('expenses').select('*').order('spent_on', {ascending:false})
  .order('created_at', {ascending:false}).limit(2500),
sb.from('settlements').select('*').order('settled_on', {ascending:false}).limit(500),
```

Los límites son globales, no por grupo, y se aplican **después de ordenar por fecha
descendente**: al superarlos se pierden los gastos *más antiguos*. `calcularSaldo()` no tiene
forma de saber que le falta información y devuelve una cifra con toda la apariencia de ser
correcta. Además, si un grupo antiguo cae fuera del corte, aparece vacío.

Nota: PostgREST tiene además un `max-rows` por defecto en el servidor (habitualmente 1000).
Si está en su valor por defecto, el `.limit(2500)` **ya está siendo recortado a 1000 hoy**.
No verificable sin acceso al proyecto.

### R8 · `escapar()` no escapa comillas, y se usa dentro de atributos HTML — **P1**

```js
function escapar(texto) {
    const d = document.createElement('div');
    d.textContent = texto ?? '';
    return d.innerHTML;          // escapa < > &  pero NO  "  ni  '
}
```

Y se usa así:

```js
' data-color="' + escapar(quien.color) + '"' + ' data-gasto="' + escapar(m.id) + '"'
```

Un `profiles.color` con el valor `x" onmouseover="…` produce **XSS almacenado** en la pantalla
de la otra persona del grupo. `color` es un campo que el usuario controla si RLS permite
actualizar el propio perfil (lo habitual). Mismo patrón en `pintarCategorias`, `pintarSelectorGrupo`
(`value="' + escapar(g.id) + '"`) y en la lista de liquidaciones.

### R9 · `aNumero()` evalúa la entrada del usuario con `Function()` — **P1**

```js
if (/[+\-*/]/.test(t) && /^[0-9+\-*\/().,]+$/.test(t)) {
    const res = Function('"use strict"; return (' + limpioExpr + ')')();
}
```

La lista blanca de caracteres es estrecha y hoy no permite escapar, pero es una construcción
`eval` sobre entrada de usuario en el camino crítico de guardar un gasto. Basta con que alguien
amplíe el regex en el futuro. Sustituible por un evaluador aritmético de 30 líneas sin coste.

### R10 · Realtime: suscripción global y sin protección contra duplicados — **P1**

```js
canal = sb.channel('gastos-compartidos')
    .on('postgres_changes', {event:'*', schema:'public', table:'expenses'}, refrescar)
    ... 4 tablas, sin filtro ...
```

- Cualquier cambio en cualquier fila de cualquier grupo recarga **las cuatro tablas enteras**.
  Una importación CSV de 300 filas dispara ~300 recargas completas encadenadas.
- `escucharCambios()` se llama desde `entrarEnLaApp()`, y `entrarEnLaApp()` se llama tanto en
  `iniciar()` como en cada evento `SIGNED_IN` de `onAuthStateChange`. El `removeChannel` previo
  mitiga la duplicación, pero `entrarEnLaApp()` se re-ejecuta entera (relee caché, refresca,
  vacía cola) en cada `SIGNED_IN`, incluidos los que dispara el navegador al recuperar el foco.
- Sin `filter` por `group_id`, si RLS no filtra, el canal **notifica cambios de grupos ajenos**.

### R11 · `vaciarCola()` puede ejecutarse dos veces a la vez — **P1**

Se dispara desde el evento `online`, desde `visibilitychange` y desde `entrarEnLaApp()`. No hay
mutex. Los `insert` están protegidos por `upsert(onConflict:'client_id')`, pero los
`expenses_delete` / `settlements_delete` no son idempotentes frente a una carrera con `refrescar()`.

### R12 · `crearGrupo()` no registra ninguna pertenencia — **P1**

```js
const { data } = await sb.from('groups').insert({ name: nombre }).select().single();
```

No hay `owner_id`, ni fila de membresía, ni nada que ate el grupo a quien lo crea. Es
justamente la pieza que hace imposible escribir una política RLS de aislamiento por grupo:
**hoy no existe el dato con el que discriminar.**

### R13 · Regex construidas con nombres de usuario sin escapar — **P2**

`escaparRegex()` existe y se usa en `interpretarDictado`, pero **no** en el importador CSV:

```js
new RegExp('solo\\s+(para\\s+|de\\s+)?' + sinTildes(p.display_name)).test(t)   // repartoDesde()
```

Un `display_name` con `(` o `[` rompe la importación con una excepción; uno con `(a+)+$`
es un ReDoS. Impacto limitado (hace falta un nombre hostil), pero es trivial de arreglar.

### R14 · PWA: iconos data-URI y riesgo de mezclar versiones — **P1**

- `manifest.json` declara **un solo icono** de 192×192 como data URI, con `purpose:"any maskable"`.
  Falta el 512×512 que Chrome exige para la instalación completa, y un data URI como único icono
  es frágil (algunos navegadores lo rechazan para el splash screen).
- `sw.js` sirve **cache-first** todo lo que no sea navegación. Cuando se separen CSS y JS del
  monolito, un `index.html` nuevo (network-first) podrá cargarse junto a un `app.js` viejo
  (cache-first) → estado incoherente. Hoy no ocurre solo porque todo está en un único archivo.
- La versión de caché (`gastos-v15`) se mantiene a mano en un comentario. Es cuestión de tiempo
  que se olvide.
- Dependencia dura de `cdn.jsdelivr.net` para `@supabase/supabase-js`, sin SRI y sin fallback.
  La primera carga sin red funciona solo si el CDN ya estaba cacheado.

### R15 · Ausencia total de pruebas y de CI — **P1**

No hay `package.json`, ni pruebas, ni workflow. Cualquier cambio en las 2703 líneas del script
se valida a ojo. Es el multiplicador de todos los riesgos anteriores.

### R16 · Otros hallazgos menores — **P2**

- `deshacerImportacion()` borra `client_id LIKE 'imp:%'` de **todo el grupo**, incluidas las
  importaciones de la otra persona.
- El `client_id` de importación es `huella(grupo|línea|fecha|concepto|importe|pagador)`. Dos CSV
  distintos con la misma fila en la misma posición colisionan y el segundo sobrescribe al primero.
- `calcularSaldo()` acumula en coma flotante y redondea solo al final; con miles de gastos hay
  deriva binaria acumulada (céntimos).
- La `SUPABASE_ANON_KEY` está en el HTML. Esto **es correcto** —la clave `anon` es pública por
  diseño—, pero solo es inocuo si RLS está activa. Se menciona para dejar constancia de que su
  presencia no es en sí misma el problema; el problema sería RLS ausente.
- `salir()` hace `location.reload()` sin esperar a que el `signOut` propague; inofensivo.

---

## 3. Riesgos que NO pueden verificarse desde el repositorio

| # | Riesgo | Por qué no se puede verificar | Impacto si se confirma |
|---|---|---|---|
| U1 | RLS desactivada en alguna de las 4 tablas | Requiere `pg_tables.rowsecurity` del proyecto real | Cualquier usuario autenticado lee y escribe **todo** |
| U2 | Políticas RLS del tipo `USING (true)` | Requiere `pg_policies` | Equivalente a no tener RLS |
| U3 | Falta el índice único en `expenses.client_id` / `settlements.client_id` | Requiere `pg_indexes` | `upsert(onConflict)` falla → **duplicación de gastos** al vaciar la cola |
| U4 | `groups` sin FK / `ON DELETE CASCADE` hacia `expenses` | Requiere `information_schema` | Borrar un grupo deja gastos huérfanos o falla |
| U5 | `max-rows` de PostgREST por debajo de 2500 | Requiere la config del proyecto | El saldo ya está truncado hoy, no a partir de 2500 |
| U6 | Existe un tercer usuario registrado | Requiere `select count(*) from profiles` | R1 ya está activo: saldos incorrectos ahora mismo |
| U7 | El alta pública de cuentas está abierta | Requiere la config de Auth | Cualquiera puede registrarse y convertirse en "la otra persona" |
| U8 | Trigger que crea `profiles` al registrarse | Requiere `pg_trigger` | Sin él, un usuario nuevo no aparece nunca en la app |
| U9 | Realtime publica las 4 tablas | Requiere `supabase_realtime` publication | Si publica sin RLS, se filtran cambios ajenos |

---

## 4. Prioridades

**P0 — puede causar pérdida de datos, saldos incorrectos o exposición.**

| Id | Riesgo | Se arregla en esta fase |
|---|---|---|
| R2 | Errores confundidos con modo offline | Sí, en el cliente |
| R3 | Cola/caché compartidas entre cuentas | Sí, en el cliente |
| R4 | Ediciones/borrados optimistas sin restaurar | Sí, en el cliente |
| R5 | Update/delete de la cola sin verificar filas afectadas | Sí, en el cliente |
| R6 | Editar/borrar offline un apunte pendiente | Sí, en el cliente |
| R7 | Saldo truncado por `limit(2500)`/`limit(500)` | Sí, en el cliente (paginación) |
| R1 | Aislamiento y modelo de 2 usuarios globales | **Parcial**: cliente preparado + migración propuesta, **no aplicada** |
| U1–U3 | RLS e índices reales | **No**: requiere datos que no tengo (sección 7) |

**P1 — corrección, seguridad defensiva y mantenibilidad.**

R8 (escapado de comillas), R9 (`Function()`), R10 (Realtime), R11 (carrera en la cola),
R12 (pertenencia al crear grupo), R14 (PWA e iconos), R15 (pruebas y CI), y la modularización.

**P2 — anotado, no bloqueante.**

R13, R16 y el resto de mejoras menores, en `docs/PENDIENTES.md`.

---

## 5. Plan de cambios de esta fase

1. **Modularización mínima sin cambio de comportamiento.** Extraer el CSS a `styles.css` y el
   script a módulos ES nativos bajo `js/`, priorizando los módulos *puros* (sin DOM) que
   permiten probar lo importante: saldos, CSV, clasificación de errores, cola offline y dictado.
   Sin build step, sin framework, sin bundler.
2. **Clasificación de errores** (`js/errores.js`): red / sesión / permiso / validación /
   desconocido. Solo `red` entra en la cola. Mensajes de interfaz diferenciados para
   *guardado en servidor*, *pendiente sin conexión*, *error que necesita intervención* y
   *sesión caducada*.
3. **Cola y caché por usuario** (`js/almacen.js`, `js/offline-queue.js`): claves versionadas
   `gastos.v2.<user_id>.*` y `owner_user_id` validado en cada tarea antes de enviarla.
4. **Mutaciones consistentes** (`js/mutaciones.js`): instantánea previa, escritura, y
   restauración del estado local si el servidor rechaza; verificación de filas afectadas en
   update/delete; fusión de ediciones sobre apuntes todavía pendientes.
5. **Carga completa paginada** (`js/supabase-data.js`): `.range()` hasta agotar, con tope de
   seguridad que **avisa en pantalla** en lugar de truncar en silencio.
6. **Realtime acotado**: un solo canal, filtrado por el grupo activo cuando es posible,
   `refrescar` con coalescencia, y guarda contra re-suscripción en `SIGNED_IN`.
7. **Migraciones SQL versionadas, no aplicadas**, bajo `supabase/migrations/`: `group_members`,
   claves foráneas, índices, restricciones y el juego completo de políticas RLS, más el
   procedimiento de validación en local/staging.
8. **Pruebas** con el runner nativo de Node (`node --test`, cero dependencias) y **GitHub Actions**
   sin secretos.
9. **PWA**: iconos PNG reales 192/512 + maskable generados de forma reproducible, versionado de
   caché automatizado y verificado en CI, y estrategia network-first para los recursos propios.

**Fuera de alcance**, según el encargo: multi-moneda, OCR, gastos recurrentes, rediseño visual,
framework, app nativa y estadísticas nuevas.

---

## 6. Criterio de conservación

La apariencia y el comportamiento observable no cambian, salvo en estos puntos, todos ellos
correcciones deliberadas de los riesgos anteriores:

- Los mensajes al guardar distinguen ahora cuatro situaciones en lugar de dos.
- Un error del servidor ya no se anuncia como "guardado localmente".
- Un borrado o edición rechazado reaparece en pantalla en lugar de quedarse oculto.
- El saldo deja de estar truncado cuando se superan 2500 gastos o 500 liquidaciones.
- La cola pendiente de otra cuenta ya no aparece al entrar con una cuenta distinta.

---

## 7. Datos necesarios para cerrar el modelo de seguridad (criterio de parada)

Para poder **finalizar y aplicar** las migraciones hace falta información que solo está en el
proyecto Supabase. Las migraciones se entregan escritas y versionadas, pero marcadas como
**no validadas** hasta obtener estas respuestas. El procedimiento y las consultas exactas están
en `supabase/README.md`.

1. Salida de `select tablename, rowsecurity from pg_tables where schemaname='public';`
2. Salida de `select * from pg_policies where schemaname='public';`
3. Volcado del esquema: `supabase db dump --schema public -f esquema.sql` (o el DDL equivalente).
4. `select count(*) from profiles;` y `select count(*) from groups;`
5. `select count(*) from expenses;` y `select count(*) from settlements;`
6. ¿Hay grupos que deban quedar visibles solo para una de las dos personas, o todos son comunes?
7. ¿Existe un trigger que cree la fila de `profiles` al registrarse un usuario?
8. ¿El alta de cuentas nuevas está abierta o cerrada en Supabase Auth?

Sin las respuestas 1–3 no es posible saber si la migración de RLS **rompe** algo que ya funciona;
sin la 6 no es posible decidir el backfill de `group_members` sin arriesgarse a ocultar datos
reales a su dueño.
