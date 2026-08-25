# Registro de cambios

Historial por versiones publicadas. Cada entrada dice qué se desplegó, con qué
SHA y qué migraciones lo acompañaron.

**El frontend se sirve por GitHub Pages directamente desde `main`**: no hay
workflow de despliegue, así que **fusionar a `main` publica**. La versión servida
es la de `VERSION_APP` en `js/config.js`, que tiene que coincidir con `VERSION`
en `sw.js` y con `version` en `manifest.json`.

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
