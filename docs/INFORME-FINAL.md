# Informe final — fase 1 de estabilización

| | |
|---|---|
| Rama de trabajo | `estabilizacion/fase-1` |
| SHA base (HEAD de `main`) | `cbc1e1336065f4184aff2e61c0df06ca22e2d25b` |
| **SHA final de la rama** | **`9d0b78312e7ec5bd556657b5ceda1e727f32e99d`** |
| Commits | 8 |
| Archivos tocados | 55 (3 modificados, 52 nuevos) |
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

### 2.3 Lo que NO se ha podido ejecutar

- **Las migraciones SQL no se han ejecutado contra ningún PostgreSQL.** En la
  máquina de trabajo no había ni PostgreSQL ni Docker. Se ha comprobado el
  equilibrio de comillas y bloques `$$`, y se ha añadido un trabajo de CI que
  las aplica de verdad sobre una base desechable, pero **ese trabajo no se ha
  llegado a ejecutar**. Su primera ejecución será el primer push a GitHub.
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
| Las migraciones no se han ejecutado nunca contra un PostgreSQL | No había ninguno disponible. CI las ejecuta en el primer push; hay que mirar ese resultado antes de tocar producción. |
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
