# Registro de cambios

Historial por versiones publicadas. Cada entrada dice qué se desplegó, con qué
SHA y qué migraciones lo acompañaron.

**El frontend se sirve por GitHub Pages directamente desde `main`**: no hay
workflow de despliegue, así que **fusionar a `main` publica**. La versión servida
es la de `VERSION_APP` en `js/config.js`, que tiene que coincidir con `VERSION`
en `sw.js` y con `version` en `manifest.json`.

---

## v18 — sin publicar · Multi-instancia

`main` pendiente de SHA.
Arquitectura en [`MULTI-INSTANCIA.md`](MULTI-INSTANCIA.md).

### Añadido

- **Instancias independientes.** La misma base de código sirve a despliegues
  que no comparten ningún dato. Se añade la instancia `alba` en `/alba/`,
  con proyecto de Supabase propio (`wspcrnqdoucohattians`). `instancias/registro.js` es la única
  fuente de verdad; `js/instancia.js` resuelve cuál está activa.
- `index.html`, `manifest.json` y `sw.js` pasan a ser **archivos generados**,
  uno por instancia, a partir de `tools/plantillas/`. Se regeneran con
  `npm run instancias` y CI falla si alguien los edita a mano. La aplicación
  (`js/`, `styles.css`, `icons/`) no se duplica.
- Workflow **Nueva instancia** (`workflow_dispatch`): registra, genera,
  prueba y abre un pull request. Funciona desde el móvil, sin ordenador.
  Rechaza una clave `service_role` descodificando el JWT.
- `tools/registrar-instancia.mjs` y `tools/instancias.mjs`, con validación
  del registro: ids y rutas repetidas, prefijos que se solapan y dos
  instancias apuntando al mismo proyecto de Supabase.

### Corregido

Tres formas en que una instancia podía destruir datos de otra. `localStorage`
y `caches` pertenecen al **origen**, no a la ruta, así que `/` y `/alba/` los
comparten. Con prueba de regresión cada una en `tests/instancias.test.js`.

- **`purgarOtrosUsuarios()` borraba la cola sin sincronizar de la otra
  instancia** al entrar. Los prefijos pasan a ser por instancia y el
  generador valida que ninguno sea prefijo de otro (`gastos.v2` frente a
  `gastos.alba.v2`: el id va antes de la versión precisamente por esto).
  Segundo cinturón: se exige que la clave tenga la forma
  `<prefijo>.<user_id>.<nombre>` con un nombre conocido.
- **El `activate` del service worker borraba la caché de la otra
  instancia**, dejándola sin aplicación offline en cada despliegue. Cada
  service worker solo borra cachés que encajen con `^<prefijo>v\d+$`.
- **El service worker de la raíz respondía por `/alba/`** con su propio
  `index.html` antes de que Alba registrara el suyo. Ahora conoce las rutas
  ajenas y no las atiende.
- `storageKey` explícito en `createClient`, para que las sesiones de dos
  instancias no puedan cruzarse.

### Compatibilidad

- La instancia `dani` **conserva sus prefijos antiguos** (`gastos.v2`,
  `gastos.correo`, `gastos-`), declarados de forma explícita en el registro.
  Cambiarlos habría borrado la cola pendiente de Dani y Pilar y duplicado el
  icono en sus pantallas de inicio. La raíz sigue siendo una instancia, no un
  índice, por el mismo motivo.
- `migrarDesdeEsquemaAntiguo()` solo adopta las claves heredadas si la
  instancia es la heredada. Una instancia nueva ni las adopta ni las borra.

### Interfaz

- Las instancias en subcarpeta muestran su id junto al número de versión.
  Con varias apps instaladas y el mismo icono, es la única forma de saber
  cuál se está mirando.

---

## v17 — 26 de agosto de 2026 · Fase 3

`main` `88011b28c769246e74e78775e40e7030bbe6c033`.
Acta completa en [`CIERRE-FASE-3.md`](CIERRE-FASE-3.md).

### Añadido

- **Trasladar saldo entre grupos** sin convertirlo en gasto ni tocar las
  estadísticas históricas: `balance_transfers`, las RPC `trasladar_saldo()` y
  `revertir_traslado()`, hoja de confirmación en dos toques, historial
  diferenciado, deshacer y encolado sin conexión idempotente.
  Migración `0007_traslado_de_saldo.sql`. Diseño en
  [`DISENO-TRASLADO-SALDO.md`](DISENO-TRASLADO-SALDO.md).

### Seguridad

- **La aplicación de viajes deja de estar abierta.** Sus 12 políticas
  `using (true)` —lecturas y escrituras para cualquier cuenta autenticada— se
  sustituyen por 12 cerradas contra `viajes_acceso`, sin correos ni UUID
  escritos en las políticas y sin enumerar usuarios.
  Migración `0006_rls_viajes.sql`, merge `b5d13ba`.
- **Incidente E12**: las 15 funciones de `public` eran ejecutables con la clave
  anónima. Sin filtración —todas resuelven contra `auth.uid()`— pero era una
  fuga de privilegio. `revoke ... from public` no retira la concesión directa a
  `anon`. Cerrado por `0008_privilegios_de_funciones.sql`, más el sustituto de
  Supabase del CI corregido para que reproduzca los privilegios por defecto
  reales, más `106_ninguna_funcion_abierta.sql` como puerta de despliegue.
- `0009_privilegios_por_defecto.sql` limpia los privilegios por defecto de los
  roles creadores administrables y **declara** los que no lo son. Ver §5 del
  acta.

### Corregido

- Los botones de la barra ya no se cortan por la derecha: saltan de línea.
  Verificado a 320, 375 y 430 px y con zoom al 125 % y 150 %.
- Las pruebas comprueban **invariantes** en vez de un recuento congelado de
  gastos, que reventaba en producción con cualquier gasto nuevo legítimo
  (merge `4a4a812`).

### Datos

- **Operación puntual, autorizada y ejecutada en una sola transacción**: se
  elimina el gasto manual «Deuda Dani225,60» —451,20 € almacenados, el apaño que
  suplía la función que ahora existe— y se traslada la deuda de verdad.
  Slovenia queda a 0,00 €; Bierzo & Asturias, con 156,09 € a nombre de Dani.
  Ningún gasto se copió ni se movió. El guion queda archivado **sin fusionar**
  en la rama `correccion/apunte-manual`, `09a20b0`; ver §6 del acta.

---

## v16 — 25 de agosto de 2026 · Fases 1 y 2

`main` `00cb707333758fee6197fe880b71ecf13a606dd4`, sobre
`cbc1e1336065f4184aff2e61c0df06ca22e2d25b`.
Acta completa en [`CIERRE-FASE-2.md`](CIERRE-FASE-2.md).

### Seguridad

- **RLS cerrada en las cinco tablas de gastos.** Producción tenía el registro
  abierto y trece políticas `using (true)`: cualquiera que se registrara podía
  leer los gastos. Migración `0004_rls.sql`.
- `group_members` pasa a ser la fuente de verdad de la pertenencia, con backfill
  explícito (`0002`, `0002b`).

### Añadido

- Restricciones e índices (`0003`), Realtime declarado por migración (`0005`).
- Cola sin conexión aislada por cuenta, saldo completo, y el proyecto
  modularizado en ES modules con pruebas de Node `--test`.

### Corregido

- El grupo de destino dejó de salir del formulario: el gasto se crea en el grupo
  activo y al editarlo conserva el suyo.
- `huella()` pasa de un djb2 de 32 bits —con 7 colisiones reales en 120.000
  filas— a 128 bits, sin colisiones en 500.000.

---

## Antes de la v16

Sin registro. El punto de partida está descrito en
[`ESTADO-INICIAL.md`](ESTADO-INICIAL.md) y auditado en
[`INFORME-AUDITORIA.md`](INFORME-AUDITORIA.md).
