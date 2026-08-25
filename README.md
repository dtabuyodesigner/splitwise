# Gastos compartidos (PWA)

Aplicación web progresiva para llevar los gastos compartidos de una pareja,
un viaje o una convivencia. HTML, CSS y JavaScript vanilla sobre Supabase.
Sin framework, sin bundler y sin paso de compilación.

> **Estado:** rama `estabilizacion/fase-1`. Primera fase de estabilización,
> seguridad y mantenibilidad. Antes de tocar el modelo de datos, lee
> `docs/SECURITY.md` y `supabase/README.md`.

---

## Puesta en marcha

La aplicación usa módulos ES nativos, así que **no funciona abriéndola con
`file://`**: hay que servirla por HTTP.

```bash
npm run servir        # http://localhost:8080
```

O con cualquier servidor estático:

```bash
python3 -m http.server 8080
npx serve .
```

Sin dependencias que instalar: `npm install` no descarga nada. Hace falta
Node 20.11 o superior para las pruebas y las herramientas.

---

## Comandos

| Comando | Qué hace |
|---|---|
| `npm test` | Pruebas automatizadas (runner nativo de Node, sin dependencias) |
| `npm run test:watch` | Igual, reejecutando al guardar |
| `npm run verificar` | Coherencia de versión, service worker, módulos e iconos |
| `npm run iconos` | Regenera los PNG de `icons/` |
| `npm run servir` | Servidor estático de desarrollo |

`npm test` y `npm run verificar` son lo que ejecuta CI en cada push. No hace
falta ningún secreto: nada de esto habla con Supabase.

---

## Estructura

```
index.html              markup: pantalla de acceso, app y 5 hojas modales
styles.css              todos los estilos, con modo oscuro
manifest.json           PWA
sw.js                   service worker
icons/                  PNG reales 192/512 + maskable, generados por script

js/
  config.js             constantes, claves, categorías, versión
  dinero.js             lectura de importes, redondeo a céntimos, formato
  fechas.js             hoy/ayer, títulos de día, lectura de fechas
  html.js               escapado de HTML seguro también en atributos
  errores.js            clasificación de errores: red / sesión / permiso / …
  balances.js           cálculo de saldos y totales (puro)
  miembros.js           pertenencia a grupos y quién es "la otra persona"
  almacen.js            localStorage aislado por usuario
  offline-queue.js      cola de envío offline
  supabase-data.js      carga paginada completa
  mutaciones.js         alta, edición y borrado con restauración
  csv.js                importación y exportación
  voice.js              interpretación del dictado (puro)
  app.js                todo lo que toca el DOM

tests/                  pruebas (node --test)
tools/                  generador de iconos, verificador, servidor
supabase/migrations/    migraciones SQL versionadas, NO aplicadas
docs/                   informes, seguridad, plan de migración, pendientes
```

Los módulos de `js/` **excepto `app.js`** son puros: no tocan el DOM ni la
red, así que se pueden importar desde Node y probar directamente. Toda la
lógica que importa —saldos, CSV, clasificación de errores, cola offline,
dictado— vive ahí.

---

## Funcionamiento

### Saldo

`payer_share` es la fracción del gasto que asume **quien pagó**:

| Valor | Significado |
|---|---|
| `0.5` | a medias |
| `1.0` | el gasto es solo suyo: nadie le debe nada |
| `0.0` | el gasto es solo del otro: le debe el importe entero |
| `0.7` | asume el 70 %, el otro le debe el 30 % |

El saldo se acumula en **céntimos enteros** y se redondea una sola vez al
final: con decenas de miles de gastos no hay deriva por coma flotante.

Si no hay exactamente dos personas identificadas en el grupo, **no se enseña
saldo**. Es deliberado: es preferible no dar una cifra a dar una incorrecta.

### Sin conexión

Lo que se apunta sin cobertura entra en una cola local y se envía solo al
recuperar la red. Cuatro estados distintos, no dos:

| Estado | Qué significa |
|---|---|
| **guardado** | El servidor lo tiene |
| **pendiente · sin conexión** | En la cola; se enviará solo |
| **rechazado por el servidor** | No se ha guardado y no se va a reintentar solo |
| **sesión caducada** | Hay que volver a entrar; lo pendiente se reintenta después |

Solo los fallos **recuperables** (red, timeout, 5xx, 429) entran en la cola.
Un rechazo de permisos o una restricción incumplida se enseñan tal cual, en
lugar de fingir que están guardados.

La cola está aislada por cuenta (`gastos.v2.<user_id>.cola`) y cada tarea
lleva su `owner_user_id`, que se valida antes de enviarla: lo que dejó
pendiente una persona no se envía nunca con la sesión de otra.

### Ediciones y borrados

Se aplican primero en pantalla, pero si el servidor los rechaza **se
deshacen**. Un `update` o un `delete` que no afecta a ninguna fila tampoco se
da por bueno: PostgREST no devuelve error en ese caso, así que se comprueban
las filas realmente afectadas.

### Importación CSV

Detecta el separador (`;`, `,`, tabulador) sin dejarse engañar por comas
dentro de comillas, entiende fechas en varios formatos y deduce la categoría
por el concepto. Cada fila recibe un `client_id` determinista, así que
**reimportar el mismo archivo no duplica nada**.

### Dictado

*"Cena en el bar 24 con 50, pagué yo"* rellena importe, concepto, categoría y
pagador. Siempre se revisa antes de guardar.

---

## Modelo de datos

| Tabla | Para qué |
|---|---|
| `profiles` | Una fila por usuario: nombre visible y color |
| `groups` | Un grupo o viaje |
| `group_members` | **Pendiente de aplicar.** Quién pertenece a qué grupo |
| `expenses` | Gastos |
| `settlements` | Pagos entre las dos personas |

El esquema completo está en `supabase/migrations/0001_baseline_esquema.sql`.

> `group_members` **no existe todavía en producción**. El frontend funciona
> igual con y sin ella: si la tabla no está (o está vacía), usa el
> comportamiento anterior. Ver `supabase/README.md` §9.

---

## Seguridad

La app es un cliente puro: no hay servidor propio donde poner reglas. **Todo
lo que impide leer o modificar datos ajenos vive en RLS.**

Las políticas propuestas están escritas y versionadas en
`supabase/migrations/0004_rls.sql`, pero **no se han aplicado**, y no se ha
podido comprobar qué políticas hay hoy en producción.

Lee `docs/SECURITY.md` antes de desplegar nada.

La clave `SUPABASE_ANON_KEY` está en `js/config.js` a la vista. Eso es
correcto: la clave `anon` es pública por diseño. Lo que nunca debe entrar en
el repositorio es la `service_role`.

---

## Versionado y caché

Tres sitios tienen que decir lo mismo:

| Sitio | Formato |
|---|---|
| `js/config.js` → `VERSION_APP` | `'v16'` |
| `sw.js` → `VERSION` | `'gastos-v16'` |
| `package.json` → `version` | `16.0.0` |

`npm run verificar` lo comprueba y CI falla si no coinciden. Si se olvida
subir la versión, el service worker no invalida la caché y los móviles se
quedan con la versión antigua.

Los recursos propios se sirven **red primero** con la copia como respaldo, así
que un `index.html` nuevo nunca se empareja con un `js/app.js` viejo. Los
externos (fuentes, CDN) van copia primero.

Al cambiar algo:

```bash
# 1. subir la versión en los tres sitios
# 2. añadir a la lista ARCHIVOS de sw.js cualquier archivo nuevo
npm run verificar
npm test
```

---

## Documentación

| Documento | Contenido |
|---|---|
| `docs/CHANGELOG.md` | Qué se publicó en cada versión, con sus SHA |
| `docs/CIERRE-FASE-2.md` | Acta de la fase 2: migraciones y despliegue |
| `docs/CIERRE-FASE-3.md` | Acta de la fase 3: Viajes, traslado de saldo y privilegios |
| `docs/DISENO-TRASLADO-SALDO.md` | Por qué un traslado no es un gasto, y cómo se modela |
| `docs/INFORME-AUDITORIA.md` | Auditoría de solo lectura: riesgos y prioridades |
| `docs/INFORME-FINAL.md` | Qué se ha cambiado, qué se ha probado y qué queda |
| `docs/ESTADO-INICIAL.md` | Estado congelado antes de empezar, con el SHA |
| `docs/SECURITY.md` | Modelo de amenazas y de acceso |
| `docs/PLAN-MIGRACION-DATOS.md` | Cómo migrar los datos reales sin perder nada |
| `docs/PENDIENTES.md` | Mejoras anotadas y no abordadas |
| `supabase/README.md` | Cómo validar las migraciones antes de aplicarlas |

---

## Diseño

Paleta *Monte de Anaga*: niebla, basalto, laurel y buganvilla. Tipografías
Bricolage Grotesque e Inter Tight con cifras tabulares. Modo oscuro
automático. Nada de esto ha cambiado en esta fase.
