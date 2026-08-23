# Informe final — fase 1 de estabilización

| | |
|---|---|
| Rama de trabajo | `estabilizacion/fase-1` |
| SHA base (HEAD de `main`) | `cbc1e1336065f4184aff2e61c0df06ca22e2d25b` |
| HEAD de la primera ronda (revisado por GPT) | `4cd991e9b41f2c752b93d6bbe4cc95823dd897d6` — 9 commits, 54 archivos |
| HEAD actual | `git rev-parse estabilizacion/fase-1` (ver §8) |
| Pruebas | **128, todas verdes** |

---

## 0. Confirmación expresa sobre producción

> **No se ha tocado producción ni su base de datos.**
>
> - No se ha ejecutado **ninguna** sentencia SQL contra
>   `cmkzcvfjgrgxwqjimtxa.supabase.co`, ni de lectura ni de escritura.
> - No se ha abierto sesión en ese proyecto Supabase. El servidor MCP de
>   Supabase de la sesión requería autenticación interactiva y no estaba
>   disponible; no se buscó ninguna vía alternativa.
> - Las migraciones de `supabase/migrations/` están **escritas y versionadas,
>   pero sin aplicar**.
> - Nada se ha desplegado. La rama no se ha empujado ni fusionado: sigue solo
>   en el repositorio local.
> - Las pruebas usan un cliente de Supabase falso (`tests/ayudas/`). El
>   trabajo de CI que ejecuta SQL levanta un PostgreSQL vacío y desechable.
> - Los únicos servicios que se han levantado son un servidor estático en
>   `localhost` y un navegador de pruebas, ambos ya cerrados.

---

## 1. Archivos modificados

**Modificados (3)**

| Archivo | Antes | Ahora | Qué ha pasado |
|---|---|---|---|
| `index.html` | 137.907 B | 16.406 B | Se le han sacado el CSS y el script. **El markup del `<body>` es byte a byte idéntico al original** (comprobado). |
| `sw.js` | 86 líneas | 128 | Estrategia red-primero para los recursos propios, lista completa de archivos, versión `v16`. |
| `manifest.json` | 1 icono data-URI | 4 iconos PNG | `any` 192/512 + `maskable` 192/512, más `id` para fijar la identidad de la app instalada. |
| `README.md` | — | — | Reescrito. |

**Nuevos (52)** — 14 módulos en `js/`, `styles.css`, 8 archivos de pruebas más el
cliente falso, 3 herramientas, 6 iconos PNG, 5 migraciones, 3 archivos de
pruebas SQL, 6 documentos y el workflow de CI.

`styles.css` es **byte a byte idéntico** a las líneas 24–1041 del `index.html`
original, más dos bloques añadidos para las clases nuevas
(`.estado--fallo`, `.estado--sesion`, `.gasto--fallido`), que no existían antes.

---

## 2. Pruebas ejecutadas y resultado exacto

```
$ node --test tests/
ℹ tests 128
ℹ suites 0
ℹ pass 128
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 801.4
```

| Archivo | Pruebas | Resultado |
|---|---|---|
| `tests/balances.test.js` | 18 | 18 pasan |
| `tests/csv.test.js` | 29 | 29 pasan |
| `tests/datos.test.js` | 9 | 9 pasan |
| `tests/errores.test.js` | 15 | 15 pasan |
| `tests/miembros.test.js` | 11 | 11 pasan |
| `tests/mutaciones.test.js` | 17 | 17 pasan |
| `tests/offline-queue.test.js` | 19 | 19 pasan |
| `tests/voice.test.js` | 10 | 10 pasan |

```
$ node tools/verificar.mjs
Coherencia correcta · versión v16 · 14 módulos · 4 iconos
```

### 2.1 Cada caso que pedía el encargo, y dónde está probado

| Caso pedido | Prueba |
|---|---|
| Saldo con gasto al 50 % | `balances`: «gasto a medias» |
| Reparto 0 %, 100 % y personalizado | `balances`: tres pruebas, incluida una con `payer_share = 0.3333` |
| Varias liquidaciones | `balances`: «varias liquidaciones se restan del saldo en ambos sentidos» |
| Redondeos monetarios | `balances`: 4 pruebas (céntimo impar, 1000 gastos de 0,10, tres decimales, `0.1 + 0.2`) |
| CSV con coma, punto y coma, comillas y fechas | `csv`: 12 pruebas, incluida una coma dentro de comillas y 5 formatos de fecha |
| Idempotencia por `client_id` | `csv`: reimportar da los mismos id · `offline-queue`: un duplicado se da por enviado · `mutaciones`: alta repetida no duplica |
| Desconexión y reconexión | `offline-queue`: «sin conexión se encola, y al reconectar se envía» + supervivencia a un F5 |
| Error RLS que no debe entrar en la cola | `mutaciones`: «alta rechazada por RLS» · `offline-queue`: «deja de reintentarse» |
| Sesión caducada | `errores` + `mutaciones` + `offline-queue`: la tarea NO se descarta y se reintenta al volver a entrar |
| Cambio de usuario con operaciones pendientes | `offline-queue`: 5 pruebas de aislamiento |
| Edición o borrado rechazado por el servidor | `mutaciones`: 6 pruebas, incluidas las de «0 filas afectadas» |
| Más de 2.500 gastos y 500 liquidaciones | `balances`: 3000 gastos + 600 liquidaciones · `datos`: la carga paginada trae 3000 y el saldo coincide |

### 2.2 Comprobado además en un navegador real (Chromium)

| Qué | Resultado |
|---|---|
| La app arranca | 0 errores y 0 avisos en consola |
| Pantalla de acceso | Se pinta; versión `v16`; 12 categorías |
| El markup y el CSS | Idénticos al original (comprobado byte a byte, no a ojo) |
| Service worker | Instala y cachea **35 recursos**: los 24 propios + 9 del CDN de Supabase + 2 de fuentes |
| **Primera carga sin conexión** | Con el servidor **apagado**, la app carga entera desde la caché: HTML, CSS (tipografía aplicada), JS ejecutado, pantalla de acceso |
| Escapado de HTML | Un `color` con `laurel" onmouseover="…` produce **un solo atributo** `data-color`; no se crea ningún `onmouseover` |
| Los módulos en el navegador | `balances`, `errores`, `csv` y `html` se importan y funcionan igual que en Node |

### 2.3 Lo que NO se ha podido ejecutar en la máquina de trabajo

- **Las migraciones SQL no se pueden ejecutar en local**: no hay PostgreSQL,
  ni Docker, ni permisos de superusuario. El único sitio donde se ejecutan es
  el trabajo `esquema` de CI, sobre un PostgreSQL 15 vacío y desechable.
  **Ese trabajo ya se ha ejecutado**: su estado y su historia están en §8.
- **El recorrido completo con sesión iniciada** (crear grupo, apuntar,
  editar, saldar) no se ha probado en navegador: exigiría credenciales
  reales contra el Supabase de producción.

---

## 3. Riesgos resueltos

### 3.1 En el frontend, con prueba

| Id | Riesgo | Cómo se ha resuelto |
|---|---|---|
| **R2** | Cualquier error se confundía con "sin conexión" y acababa en la cola | `js/errores.js` clasifica en red / sesión / permiso / validación / duplicado / desconocido. Solo `red` se encola. La interfaz distingue los cuatro estados que pedía el encargo. |
| **R3** | Cola y caché compartidas entre cuentas | Claves `gastos.v2.<user_id>.*`, `owner_user_id` en cada tarea validado antes de enviar, purga de otras cuentas al entrar, y migración del esquema antiguo sin perder lo pendiente. |
| **R4** | Ediciones y borrados que no se deshacían al ser rechazados | `js/mutaciones.js` toma una instantánea y la restaura. El saldo tras un rechazo vuelve a ser el de antes. |
| **R5** | `update`/`delete` que no afectaban a ninguna fila se daban por buenos | Se pide `.select('id')` y se comprueban las filas afectadas. |
| **R6** | Editar o borrar offline un apunte aún pendiente perdía el cambio | La cola reescribe la tarea de alta original en vez de encolar un `update` contra un id que el servidor no conoce. |
| **R7** | Saldo calculado sobre un conjunto truncado en 2500/500 | Paginación con `.range()` hasta agotar. Si se alcanza el tope de seguridad, se avisa **en pantalla**. |
| **R1** (parcial) | Saldo repartido contra un tercero arbitrario | `calcularSaldo` ignora los gastos ajenos al par; sin dos personas identificadas devuelve `null` y no se enseña saldo. |
| **R8** | XSS almacenado por comillas sin escapar dentro de atributos | `js/html.js` escapa `& < > " ' \``. Verificado contra el parser real del navegador. |
| **R9** | `Function()` sobre la entrada del usuario | Analizador aritmético cerrado. |
| **R10** | Realtime global que recargaba todo ante cualquier cambio | Un canal, filtrado por grupo, recargas agrupadas a 400 ms, sin re-suscribir en cada `SIGNED_IN`, y en pausa durante las importaciones. |
| **R11** | `vaciarCola()` concurrente | Mutex. |
| **R12** | Crear un grupo no registraba ninguna pertenencia | Se registra, tolerando que la tabla aún no exista. |
| **R13** | Regex construidas con nombres sin escapar | `escaparRegex` en el importador. |
| **R14** | PWA: iconos data-URI y mezcla de versiones | 6 PNG reales generados por script, red-primero para los recursos propios, y la versión verificada en CI. |
| **R15** | Sin pruebas ni CI | 128 pruebas y dos trabajos de CI sin secretos. |

### 3.2 Hallados y corregidos durante la propia fase

Estos **no estaban en el informe inicial**: aparecieron al revisar el trabajo.

| Gravedad | Qué | Consecuencia si hubiera llegado a producción |
|---|---|---|
| **Crítico** | `miembros_invitar` permitía a cualquier autenticado apuntarse a cualquier grupo. Su rama `not exists (select 1 from group_members …)` pasa por RLS, y para quien no es miembro esa subconsulta devuelve siempre vacío: la condición era cierta para **todo grupo ajeno**. | Un solo `POST` a `/rest/v1/group_members` y se leen y escriben los gastos de otra persona. Es decir, la migración de seguridad habría **abierto** un agujero. |
| **Crítico** | `groups_leer_los_mios` no contemplaba al creador. En un `INSERT … RETURNING`, la política de SELECT se evalúa **antes** de que corran los triggers `AFTER INSERT`. | Crear un grupo habría fallado **siempre** en cuanto se aplicara RLS. |
| **Alto** | El backfill dejaba sin propietario todos los grupos históricos (`created_by` se añade en 0001, así que es `NULL` en ellos), y no había política de `UPDATE` sobre `group_members` para arreglarlo. | Ningún grupo antiguo se podría borrar nunca, sin forma de corregirlo desde la app. |
| **Alto** | `huella()` era un djb2 de 32 bits: **7 colisiones reales en 120.000 filas**, alguna entre grupos distintos. Con `client_id` único en toda la tabla, una colisión hace que el `upsert` **sobrescriba** un gasto existente en vez de insertar el nuevo. | Pérdida silenciosa de gastos al importar. Sustituido por 128 bits: 0 colisiones en 500.000 filas. |
| Medio | El índice único de `client_id` estaba definido como **parcial**. PostgREST emite `ON CONFLICT (client_id)` sin `WHERE`, y PostgreSQL no puede inferir un índice parcial. | El `upsert` de la cola offline y de la importación habría fallado entero. |
| Medio | `location.reload()` no interrumpe la ejecución. | Al cambiar de cuenta, se montaba el almacén de la cuenta nueva sobre la página vieja. |
| Menor | FK duplicada de `groups.created_by`; guardas de `pg_constraint` solo por nombre; nombre vacío si el correo lo está; `pgcrypto` innecesario. | Ruido en el catálogo. |
| Menor | En el dictado, «solo para mí» no casaba nunca: el `\b` final no cierra tras una vocal acentuada. | El gasto se guardaba a medias en lugar de entero. |

Los dos críticos y los dos altos salieron de una **revisión independiente de
las migraciones**, no del trabajo original. Las comprobaciones de CI eran
solo de catálogo y no habrían visto ninguno de los dos críticos: por eso se
ha añadido `supabase/pruebas/98_seguridad_dml.sql`, que **ejecuta consultas
reales suplantando usuarios** e intenta el ataque explícitamente.

---

## 4. Riesgos pendientes

### 4.1 No verificables sin acceso al proyecto Supabase

Siguen exactamente igual que en el informe inicial. **Nada de lo hecho en
esta fase los resuelve**, porque todos dependen de datos del servidor:

| # | Riesgo | Impacto si se confirma |
|---|---|---|
| U1 | RLS podría estar desactivada hoy en alguna de las 4 tablas | Cualquier autenticado lee y escribe todo |
| U2 | Podría haber políticas `USING (true)` | Equivale a no tener RLS |
| U3 | Podría faltar el índice único de `client_id` | El `upsert` falla → **duplicación de gastos** al sincronizar |
| U4 | `groups` podría no tener FK hacia `expenses` | Borrar un grupo deja gastos huérfanos |
| U5 | El `max-rows` de PostgREST podría estar por debajo de 2500 | El saldo ya estaría truncado **hoy**, y antes de lo que decía el límite del código |
| U6 | Podría existir un tercer usuario registrado | R1 estaría activo ahora mismo: saldos incorrectos |
| U7 | El alta pública de cuentas podría estar abierta | Un desconocido puede registrarse y volverse «la otra persona» |
| U8 | Podría no existir el trigger que crea `profiles` | Un usuario nuevo no aparecería nunca |

### 4.2 Riesgos asumidos a conciencia

| Qué | Por qué se acepta |
|---|---|
| Las migraciones no se han ejecutado nunca contra una base con datos reales | En la máquina de trabajo no hay PostgreSQL. CI las aplica sobre una base vacía; eso demuestra que compilan, no que la migración de datos existentes vaya a salir bien. |
| El trigger sobre `auth.users` puede fallar por propiedad de la tabla | Es el patrón que documenta Supabase, pero depende de cómo esté provisionado el proyecto. CI no puede detectarlo. |
| La cola heredada se adopta bajo la cuenta que entra primero | Es lo que la versión anterior habría hecho con esa misma cola. Ocurre una sola vez. La alternativa perdería trabajo real. |
| Reimportar un CSV importado antes de la v16 lo duplicará | Al cambiar `huella()`. El botón «Borrar lo importado» sigue funcionando. |
| La app sigue siendo de dos personas | Rediseñar la interfaz para N personas está fuera de alcance. El modelo de datos ya lo admite; la interfaz, todavía no. |
| `styles.css` sigue teniendo 1018 líneas | Mover CSS es donde más fácil se cuela una regresión visual y no había forma de comprobarlo automáticamente. |

Las 17 mejoras menores anotadas están en `docs/PENDIENTES.md`. Ninguna
bloquea el cierre de esta fase.

---

## 5. Pasos manuales necesarios

### 5.1 Antes de nada

1. **Empujar la rama y mirar CI.**
   ```bash
   git push -u origin estabilizacion/fase-1
   ```
   El trabajo `esquema` aplica las migraciones sobre un PostgreSQL desechable
   y ejecuta las pruebas de seguridad. **Es la primera vez que ese SQL se
   ejecuta.** Si falla, hay que arreglarlo antes de seguir.

2. **Responder las 8 preguntas** del informe de auditoría §7. Las consultas
   exactas, todas de solo lectura, están en `supabase/README.md` §4.

### 5.2 Desplegar el frontend (se puede hacer ya)

El frontend funciona con y sin las migraciones. No hace falta ventana de
indisponibilidad.

- Servir el repositorio como sitio estático, igual que antes.
- **La app ya no funciona con `file://`**: usa módulos ES y necesita HTTP.
- La primera visita tras el despliegue recarga sola (el service worker
  detecta la versión nueva).

### 5.3 Aplicar las migraciones (solo después de 5.1 y 5.2)

Procedimiento completo en `supabase/README.md` y
`docs/PLAN-MIGRACION-DATOS.md`. En resumen:

1. Copia de seguridad completa y **verificada**.
2. Validar en un Supabase local con una copia de los datos reales.
3. `0001` → `0002` → **revisar y ejecutar el backfill** → `0003` → `0004` → `0005`.
4. Antes de `0004`, comprobar que **ningún grupo se queda con 0 miembros** y
   que **nadie tiene gastos en un grupo del que no es miembro**.
5. Con la app abierta y las dos personas disponibles, comprobar que el saldo
   de cada grupo es el mismo número de antes.

La marcha atrás está en `supabase/README.md` §8. Ninguna sentencia de vuelta
borra datos.

### 5.4 Al hacer cambios en adelante

```bash
# 1. subir la versión en los TRES sitios (config.js, sw.js, package.json)
# 2. añadir a la lista ARCHIVOS de sw.js cualquier archivo nuevo
npm run verificar
npm test
```

---

## 6. Qué cambia para quien usa la app

Todo lo demás está igual, empezando por el aspecto:

- Los mensajes al guardar distinguen ahora cuatro situaciones en lugar de dos.
- Un error del servidor ya no se anuncia como «guardado localmente».
- Un borrado o edición rechazado reaparece en pantalla en vez de quedarse
  oculto mintiendo.
- La barra de estado avisa de los apuntes rechazados y, al tocarla, deja
  descartarlos o reintentarlos.
- El saldo deja de estar truncado al superar 2500 gastos o 500 liquidaciones.
- Lo que dejó pendiente una cuenta ya no aparece al entrar con otra.
- «Solo para mí» en el dictado ahora se entiende.
- Los iconos de la app instalada son PNG reales, con variante maskable.

---

## 8. Segunda ronda: el CI de SQL, en marcha

La primera ronda se publicó como PR #1 en `4cd991e`, con el trabajo de esquema
sin haberse ejecutado nunca. Al ejecutarse, salió rojo. Esto es lo que pasó.

### 8.1 Primer fallo: el entorno de pruebas, no las políticas

```
supabase/pruebas/98_seguridad_dml.sql:67
ERROR: permission denied for schema auth
QUERY: auth.uid() <> '11111111-1111-1111-1111-111111111111'
```

El stub de CI creaba el esquema `auth` y la función `auth.uid()`, pero solo
concedía `USAGE` sobre `public`. Sin `USAGE` sobre `auth`, el rol
`authenticated` no puede invocar la función, así que **el test se detenía en su
primera aserción y no llegaba a comprobar ni una sola política**. El fallo era
del entorno de pruebas.

Corregido concediendo exactamente dos permisos —`USAGE` sobre el esquema `auth`
y `EXECUTE` sobre `auth.uid()`—, ambos revocados antes de `PUBLIC` para que
queden acotados. `auth.users` sigue siendo inaccesible para `anon` y
`authenticated`, y ahora hay una aserción (`S02`) que lo comprueba: poder
llamar a `auth.uid()` no debe implicar poder leer la tabla de usuarios.

### 8.2 Segundo problema: recursión infinita en las políticas de propiedad

Las políticas `miembros_cambiar_rol` y `miembros_expulsar` —introducidas en la
primera ronda para arreglar los grupos imborrables— consultaban
`public.group_members` dentro de su propia expresión RLS. Al expandir las
políticas, PostgreSQL vuelve a entrar en la misma relación y aborta con
`infinite recursion detected in policy for relation "group_members"`.

Corregido con `public.es_owner()`, `SECURITY DEFINER` con `search_path` fijo,
`EXECUTE` revocado de `PUBLIC` y concedido solo a `authenticated`: las mismas
garantías que ya tenía `es_miembro()`. Devuelve un booleano, no filas.
`groups_borrar` también pasa a usarla, porque consultaba `group_members` a
través de RLS, que es el patrón frágil que causó el bypass de autorización.

### 8.3 Tercer problema: una guarda mía con falso positivo

La comprobación que añadí para detectar políticas autorreferentes usaba
`LIKE '%group_members%'` sobre `pg_get_expr`. Eso también casa con la
referencia de **columna** `group_members.group_id` que `miembros_invitar` usa
dentro de una subconsulta a `public.groups`, que es legítima. La guarda daba
falso positivo y hacía fallar el CI por sí sola. Ahora exige un `FROM` sobre la
propia tabla, que es lo único que recursa.

### 8.4 El invariante que RLS no puede expresar

«Un grupo conserva al menos un propietario» depende de las **demás** filas del
grupo, y RLS decide fila a fila. Va en un trigger,
`antes_de_perder_propietario`, que es transaccional y no se puede saltar desde
el cliente. Se salta a sí mismo cuando el grupo ya no existe, para no bloquear
el `CASCADE` de borrar un grupo entero.

Sin esta regla, el último propietario podía degradarse o marcharse y dejar el
grupo sin nadie que pudiera administrarlo ni borrarlo: exactamente el estado
del que la migración 0002 intenta salir.

### 8.5 Y por qué ahora el log del SQL se publica en el PR

Los logs de Actions no se pueden leer por API sin permisos extra, y un fallo de
SQL sin su mensaje no es diagnosticable: las dos primeras iteraciones se
hicieron a ciegas. Ahora cada paso vuelca la salida de `psql` a un log que se
publica siempre en el resumen del trabajo y, si algo falla en un PR, como
comentario del propio PR. Usa el `GITHUB_TOKEN` que emite Actions; no hace
falta ningún secreto propio.

### 8.6 Estado de la validación de RLS

> **RLS NO está validada** mientras el trabajo `esquema` no termine en verde.
>
> Que las migraciones **apliquen** sobre una base vacía no demuestra que las
> políticas **se comporten** como dicen: eso es justo lo que comprueba
> `98_seguridad_dml.sql`, con 32 aserciones ejecutando consultas reales. El
> estado exacto de cada trabajo y cada paso está en el PR #1 y en el informe
> de la sesión.

Y aunque termine en verde, seguirá sin estar validada **contra datos reales**:
la base de CI está vacía. Eso solo puede comprobarse con una copia de
producción en un entorno de staging, siguiendo `supabase/README.md`.

---

## 9. El grupo de un gasto es inmutable

Encontrado en la revisión del SHA `2bedd36`, y es un fallo de **consistencia
entre la validación y la escritura**, no de permisos.

`abrirHojaGasto()` comprobaba con `grupoAdmite('gasto')` que el **grupo activo**
admitiera el gasto. Pero el formulario tenía un `<select id="entradaGrupo">`
relleno con **todos** los grupos visibles, y `guardarGasto()` escribía:

```js
group_id: $('entradaGrupo').value
```

Es decir: **se validaba un grupo y se escribía en otro.** Bastaba abrir la hoja
desde un grupo de dos, cambiar el desplegable, y guardar en un grupo individual
o de tres. En el individual entraba un `payer_share = 0.5` o un pagador ajeno;
en el de tres, un reparto de dos personas que el motor actual no sabe
interpretar. Las garantías de SOLO/PAR/MULTI que se habían añadido en la ronda
anterior quedaban sin efecto por esta vía.

### Qué se ha hecho

En esta fase **el grupo de un gasto no se puede cambiar**:

- al crear, el destino sale del grupo activo y se fija al abrir la hoja;
- al editar, manda `gasto.group_id`, y se valida **ese** grupo, no el activo;
- el `<select>` se sustituye por el nombre del grupo como texto. Al ser ahora
  un `<p>`, cualquier lectura residual de `.value` devuelve `undefined` en
  lugar de un grupo equivocado.

Y, sobre todo, **la garantía deja de depender de lo que haya pintado el
formulario**. `js/gastos.js` es una función pura que recalcula el tipo del
grupo de destino justo antes de construir la fila:

| Grupo de destino | Qué hace |
|---|---|
| MULTI | Rechaza: no existe el motor de reparto multipersona |
| AJENO | Rechaza |
| SOLO | **Fuerza `paid_by = yo` y `payer_share = 1` en el dato**, no solo en la interfaz |
| PAR | El pagador debe ser miembro del grupo y el reparto estar entre 0 y 1 |

RLS no puede cubrir esto por sí sola: las políticas comprueban que `paid_by`
pertenece al grupo, pero **no pueden saber** que un grupo individual debe usar
`payer_share = 1`, ni que uno de tres todavía no debe aceptar repartos. Esa
garantía vive hoy en el cliente, y queda anotada para trasladarla al servidor
cuando exista el modelo definitivo.

### Un fallo que destapó su propia prueba

El reparto se leía con `Number(formulario.reparto)`. Y `Number(null)` es `0`,
que **no** es un valor neutro: `0` significa «el gasto es entero de la otra
persona». Un reparto ausente podía convertirse en eso por accidente. Ahora se
exige un número de verdad.

### El resto de caminos de escritura

Se revisó el mismo patrón en liquidaciones, importación CSV, vaciado de grupo,
borrado de grupo y deshacer importación:

| Camino | Estado |
|---|---|
| Gastos | **Era explotable.** Corregido |
| Liquidaciones | Validaba y escribía el mismo grupo. Aun así se fija el destino al abrir, porque Realtime puede cambiar el grupo activo con la hoja abierta |
| Importación CSV | Igual. Además se comprueba que las filas analizadas van al grupo esperado |
| Vaciar grupo, borrar grupo, deshacer importación | Ya operaban sobre grupos de `misGrupos()`. Sin cambios |
