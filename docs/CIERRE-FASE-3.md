# Cierre de la Fase 3

**26 de agosto de 2026.** Viajes cerrada, traslado de saldo desplegado, y el
apaño manual que lo suplía, eliminado.

Este documento es el acta. Los documentos de trabajo —`DISENO-TRASLADO-SALDO.md`,
`SECURITY.md`— se conservan como están; describen el diseño y las reglas, no el
estado final.

---

## 1. Qué hay desplegado

| | |
|---|---|
| `main` | `88011b28c769246e74e78775e40e7030bbe6c033` |
| `main` antes de la fase 3 | `3c07ec5def5bc937c5f22a0fe1f5f1356f025649` |
| Merge de la seguridad de Viajes (PR #3) | `b5d13baf3eeba1656c89f61c5daf5b0e413149d7` |
| Merge de los invariantes (PR #4) | `4a4a8125c465651a438dc2da89c924aa97ffffbe` |
| Merge del traslado de saldo (PR #5) | `88011b28c769246e74e78775e40e7030bbe6c033` |
| SHA revisado de Viajes | `9d62b1c66618a448bc1e433b287e66fe9923a94d` |
| SHA revisado del traslado | `a5e3c497c7a12f5de516f128072542a16253fc38` |
| Guion de la corrección puntual | `09a20b0b33c68e3f182f2f095ca25e92aef19e9a` (rama `correccion/apunte-manual`, **sin fusionar** — ver §6) |
| Versión servida | **v17** (`sw.js` → `gastos-v17`) |

Los tres merges son **merge commits reales**, sin squash ni rebase. Las seis
ramas se conservan.

**El frontend se sirve por GitHub Pages directamente desde `main`.** Sigue sin
haber workflow de despliegue: fusionar a `main` publica.

---

## 2. Migraciones aplicadas

| | Qué hace | Estado |
|---|---|---|
| `0006_rls_viajes.sql` | Cierra la aplicación de viajes | Aplicada y validada |
| `0007_traslado_de_saldo.sql` | `balance_transfers`, las dos RPC y sus protecciones | Aplicada y validada |
| `0008_privilegios_de_funciones.sql` | Retira `EXECUTE` a `PUBLIC` y a `anon` de todas las funciones de `public` | Aplicada y validada |
| `0009_privilegios_por_defecto.sql` | Limpia los privilegios **por defecto** de los roles creadores que se pueden administrar | Aplicada, con limitación declarada (§5) |

`0006` se desplegó por separado y antes que las demás: cerraba una puerta
abierta, y el resto podía esperar.

---

## 3. Las dos correcciones de seguridad

### 3.1 Viajes estaba abierta a cualquier cuenta autenticada

`viajes`, `viaje_diario` y `viaje_fotos` tenían **12 políticas `using (true)`**:
cualquiera que se registrara podía leerlas y escribirlas. `0006` las sustituye
por 12 políticas cerradas contra una tabla de acceso explícita,
`viajes_acceso`, consultada por `public.puede_viajes()`.

Sin correos ni UUID escritos en las políticas, sin enumerar usuarios y sin
conceder acceso por el mero hecho de tener perfil. El backfill mete a las dos
personas que ya usaban la aplicación, y a nadie más. Lo comprueban las 21
aserciones de `97b_seguridad_viajes.sql`.

### 3.2 Incidente E12 — las funciones eran ejecutables por `anon`

Detectado **después** de aplicar `0007`: las 15 funciones de `public` podían
invocarse con la clave anónima. No se filtró nada —todas resuelven contra
`auth.uid()` y devolvían «No hay sesión»— pero era una fuga de privilegio real.

Causa de que se colara: `revoke ... from public` **no retira una concesión
directa a `anon`**, y Supabase concede `EXECUTE` a `anon`, `authenticated` y
`service_role` por privilegios por defecto. El CI no lo vio porque su sustituto
de Supabase no reproducía esos privilegios: se estaba probando sobre una base
**más cerrada** que producción.

Cerrado con tres cosas, no una:

1. `0008` revoca explícitamente de `PUBLIC` y de `anon`, y concede a
   `authenticated` solo las 9 firmas que la aplicación llama.
2. `00_stub_supabase.sql` ahora sí declara los privilegios por defecto de
   Supabase, así que el CI corre sobre la misma base que producción.
3. `106_ninguna_funcion_abierta.sql` es una **puerta**: falla si alguna función
   de `public` queda abierta. Corre en el CI y en cada despliegue.

---

## 4. El traslado de saldo, y la corrección del apunte manual

### 4.1 La función

Un traslado **no es un gasto**: es una fila de `balance_transfers` con dos
liquidaciones vinculadas, una en cada grupo. `expenses` no se toca, así que ni
el total gastado ni las estadísticas por categoría cambian. Esa era la
exigencia del enunciado y se cumple por construcción, no por disciplina.

Protecciones, todas en el servidor: un *constraint trigger* diferido que hace
imposible medio traslado, triggers de inmutabilidad, marca de transacción que
el cliente no puede fijar, clave de idempotencia con índice único, y
`security invoker` para que la RLS siga mandando. 19 comprobaciones en
`102_validar_0007.sql`, 27 en `101_traslado_de_saldo.sql`.

### 4.2 La operación real, del 26 de agosto de 2026

El caso que pedía la función se resolvía a mano con un gasto falso llamado
«Deuda Dani225,60», almacenado por **451,20 €**. Contarlo *y además* trasladar
habría contado la deuda dos veces, así que borrarlo y trasladar tenían que
entrar juntos o no entrar. Se ejecutaron en **una sola transacción**.

Antes → después, en euros:

| | Antes | Después |
|---|---|---|
| Slovenia | −225,59 € | **0,00 €** |
| Bierzo & Asturias | −156,10 € | **−156,09 €** (Dani debe a Pilar) |
| Gastos en Bierzo | 3 | **2** |
| Total gastado de Bierzo | 590,20 € | **139,00 €** |
| Traslados | 0 | **1**, de 225,59 €, con **2** liquidaciones |
| El apunte manual | ahí | **eliminado** |

El céntimo de diferencia —156,10 → 156,09— no es un error: es el redondeo de un
reparto impar, y el guion lo exigía de antemano.

Evidencia, tal cual la imprimió producción:

```
[1] ok — el gasto es exactamente el diagnosticado (45120 céntimos)
[2] ok — Slovenia -22559, Bierzo -15610, 0 traslados, total gastado 59020
[3] ok — apunte manual borrado
[4] ok — Bierzo pasa a 6950, total gastado 13900 con 2 gastos
[5] ok — traslado ejecutado por 22559 céntimos
[6] ok — Slovenia 0, Bierzo -15609, suma -15609 conservada
[7] ok — invariantes, RLS, Splitwise y Viajes intactos
CORRECCIÓN CORRECTA — lista para confirmar
```

Validación inmediatamente posterior, sobre producción:

```
 profiles | groups | expenses | settlements | group_members
        2 |      3 |       53 |           3 |             6

Invariantes de integridad correctos
Ninguna función abierta
Validación de 0007 correcta · nada de lo probado ha quedado escrito   (19/19)
```

`expenses` pasa de 54 a 53: el gasto borrado, y ninguno más.

### 4.3 Por qué la aplicación muestra hoy 99,09 € y no 156,09 €

Después de la corrección, Dani apuntó **dos gastos legítimos** en Bierzo &
Asturias. La cifra que enseña la pantalla los incluye. **No es un fallo**, y
conviene dejarlo escrito para que dentro de seis meses nadie lo persiga: la
foto de «después» de esta acta es la del momento de la operación, no la de hoy.

---

## 5. Limitación declarada: los privilegios por defecto de `supabase_admin`

En `public` hay ACL por defecto de **dos** roles: `postgres` —con el que se
despliega— y `supabase_admin`, de la plataforma. `0009` limpia el primero. El
segundo respondió, y así debe ser:

```
permission denied to change default privileges
```

No se ha rodeado. Nada de `SET ROLE`, de concederse el rol ni de una función
`SECURITY DEFINER`: sería escalar privilegios para modificar algo que no es de
esta aplicación. `0009` lo **declara y sigue**, en vez de abortar —abortar
dejaría también sin hacer la parte que sí está en su mano—:

```
Privilegios por defecto limpiados en el/los rol(es): postgres
LIMITACION DECLARADA — sin permiso para cambiar los privilegios por defecto de:
supabase_admin. Son roles gestionados por Supabase, no de esta aplicacion.
AVISO: PostgreSQL seguira concediendo EXECUTE a PUBLIC en cada funcion nueva.
Todas las funciones de la aplicacion pertenecen a postgres
```

Hay además una limitación **nativa de PostgreSQL**, aceptada a propósito:
`ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` es un
no-op —borra la fila de `pg_default_acl` y devuelve al comportamiento de
fábrica, que *es* `EXECUTE TO PUBLIC`—. Se descartó el *event trigger* que lo
arreglaría: exige superusuario y cambiaría el comportamiento global de la base.

**Por qué no importa**, mientras se cumpla lo que sí controlamos: las funciones
de esta aplicación las crean sus migraciones como `postgres` (lo comprueba
**P13**), cada migración revoca explícitamente, y **`106` falla** si alguna
queda abierta. La regla de tres líneas para toda función nueva está en
[`SECURITY.md`](SECURITY.md).

---

## 6. Decisión sobre `107_corregir_apunte_manual.sql`

**No se fusiona a `main`. Se conserva archivado en la rama
`correccion/apunte-manual`, en `09a20b0`, como evidencia documental.**

El razonamiento:

- **Es irrepetible por construcción.** Exige tres condiciones que ya no se
  cumplen y que no puede volver a cumplir: que exista un gasto con el resorte
  `c0b47a8b` por 451,20 € (borrado), que `balance_transfers` esté **vacía** (hay
  uno), y que los saldos de partida sean −225,59 y −156,10 (son 0 y −156,09).
  Cualquiera de las tres lo aborta en la primera comprobación, sin cambiar nada.
  Y su clave de idempotencia ya está usada, lo que lo bloquearía otra vez.
- **Pero «aborta si lo ejecutas» no es razón para publicarlo.** En `main` sería
  un guion que borra un gasto y mueve dinero, junto a los que el CI y
  `aplicar-migraciones.sh` sí ejecutan. La distancia entre «no se ejecuta» y «se
  ejecutó por error» es un `-f` mal escrito.
- **La rama ya es el archivo que hace falta.** Contiene `main` `88011b2` entero
  más el guion; no se borra ninguna rama remota; su SHA está escrito aquí. Quien
  necesite auditar qué se ejecutó exactamente lo tiene, íntegro y fechado.
- Lo que sí queda en `main` es lo **reutilizable**: `103` (diagnóstico, solo
  lectura) y `100`/`102`/`106` (validación). El apaño puntual, no.

En consecuencia, `~/corregir-apunte.sh` —lo único que podía lanzar `107` contra
producción— se retira en la limpieza.

---

## 7. Lo que queda vivo

### Funciones pendientes, cada una por su cuenta

- **Grupos de más de dos personas** — §0.a de [`PENDIENTES.md`](PENDIENTES.md).
- **Mover un gasto entre grupos** — §0.c. No confundir con trasladar saldo, que
  ya está hecho: aquella cambia dónde ocurrió el consumo, esta solo la deuda.
- **Invitaciones a un grupo** — §7.

Trasladar saldo sale de esa lista: resuelto, desplegado y verificado.

### Fronteras declaradas y no validadas

- Los privilegios por defecto de `supabase_admin` (§5).
- **`supabase_realtime_messages_publication`** pertenece al esquema `realtime`,
  que estas migraciones no tocan.
- **El CI valida sobre PostgreSQL 15 y producción es 17.** Sigue igual que al
  cerrar la fase 2; lo cubre la validación sobre copia real, que sí es 17.
- **No hay pruebas de interfaz.** El traslado tiene 27 aserciones de servidor y
  pruebas de módulo puro, pero el recorrido de pantalla se verificó a mano.

---

## 8. Lo que se aprendió por el camino

1. **Un verde puede significar que la comprobación no se ejecutó.** Se repitió,
   con variantes nuevas: `exception when others then null` imprimiendo `ok`,
   una consulta de privilegios que omitía `PUBLIC`, y una prueba que creía
   examinar un grupo saldado y examinaba uno vacío.
2. **Congelar un recuento en una prueba es sembrar un fallo.** `expenses = 53`
   reventó en producción por un gasto legítimo nuevo. Sustituido por
   invariantes en `100_invariantes.sql`. Fue la segunda vez que aparecía el
   mismo patrón; de ahí que ahora haya una prueba dedicada a no repetirlo.
3. **El entorno de pruebas debe ser tan permisivo como producción, no más.** El
   incidente E12 existió porque el sustituto era más estricto que la realidad.
4. **PostgreSQL y JavaScript no redondean igual.** `round()` redondea alejándose
   del cero y `Math.round` hacia +∞: `round(-500.5)` da −501 y `Math.round`, −500.
   El saldo se calcula con `floor(0.5 + x)` en los dos lados.
5. **El número autorizado hay que recalcularlo, no aceptarlo.** El primer
   borrador esperaba que el total de Bierzo quedara en 364,60 €: restaba la
   *deuda* (225,60) en vez del *importe almacenado* (451,20). El ensayo sobre
   PostgreSQL desechable lo cazó antes de tocar producción.
