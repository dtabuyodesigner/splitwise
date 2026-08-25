# Seguridad

Documento de la fase 1 de estabilización. Describe el modelo de seguridad
**previsto**, qué parte está implementada y qué parte sigue pendiente de
aplicarse en el servidor.

---

## 1. Advertencia principal

> **No se ha podido inspeccionar el proyecto Supabase de producción.** Este
> documento no afirma que la aplicación sea segura hoy, ni que sea insegura.
> Afirma qué hace falta para que lo sea y cómo comprobarlo.
>
> Las respuestas que faltan están en `docs/INFORME-AUDITORIA.md` §7 y las
> consultas para obtenerlas en `supabase/README.md` §4.

---

## 2. Modelo de amenazas

La aplicación es un cliente puro: el navegador habla directamente con
PostgREST usando la clave `anon` y el JWT del usuario. **No hay ninguna capa
de servidor propia donde poner reglas de negocio.** Por tanto:

> Todo lo que impide que alguien lea o modifique datos ajenos vive en RLS.
> Si RLS no está bien puesta, no hay nada más que proteja los datos.

Quién puede intentar qué:

| Actor | Puede | Qué lo detiene |
|---|---|---|
| Cualquiera en internet | Leer `index.html` y la clave `anon` | Nada, y es correcto: la clave `anon` es pública por diseño |
| Cualquiera en internet | Registrarse, si el alta está abierta | La configuración de Auth |
| Usuario autenticado | Lanzar cualquier consulta contra las 4 tablas | **Solo RLS** |
| Miembro de un grupo | Ver y modificar todo lo del grupo | Es intencionado |
| Persona con acceso físico al móvil | Leer `localStorage` | El bloqueo del dispositivo |

## 3. Sobre la clave `anon` en el HTML

`js/config.js` contiene `SUPABASE_ANON_KEY` en claro. **Esto es correcto.**
La clave `anon` está diseñada para ser pública: identifica al proyecto, no
autoriza nada por sí sola. Todas las peticiones llevan además el JWT del
usuario, y es ese JWT el que RLS evalúa.

Lo que **nunca** debe aparecer en este repositorio es la clave
`service_role`, que sí salta RLS. Si alguna vez se filtra, hay que rotarla
de inmediato desde *Project settings → API*.

---

## 4. Modelo de acceso previsto

Definido en `supabase/migrations/0004_rls.sql`. **Todavía no aplicado.**

La pieza que hoy falta es la tabla de pertenencia. Sin ella no existe el
dato con el que decidir quién puede ver qué grupo:

```
group_members(group_id, user_id, role)
```

Con ella, las reglas son:

| Tabla | Leer | Crear | Modificar | Borrar |
|---|---|---|---|---|
| `profiles` | El propio + quien comparta grupo | Solo el propio | Solo el propio | Nadie (cascada de `auth.users`) |
| `groups` | Solo los grupos propios | Cualquiera (queda como `owner`) | Cualquier miembro | Solo el `owner` |
| `group_members` | Miembros del grupo | Cualquier miembro (invitar) | — | El `owner`, o uno mismo (salirse) |
| `expenses` | Miembros del grupo | Miembros, y el pagador también debe serlo | Miembros | Miembros |
| `settlements` | Miembros del grupo | Miembros, y ambas partes deben serlo | Miembros | Miembros |

Decisiones deliberadas:

- **Cualquier miembro edita y borra los gastos de los demás.** Es lo que la
  app ya hace hoy y lo que una pareja espera. La protección está en el
  perímetro del grupo, no dentro.
- **Borrar un grupo lo reserva quien lo creó**, porque arrastra en cascada
  los gastos de las dos personas.
- **`es_miembro()` es `SECURITY DEFINER`.** Es necesario: las políticas de
  `groups`, `expenses` y `settlements` consultan `group_members`, y si esa
  consulta pasara a su vez por RLS habría recursión infinita. La función
  salta RLS pero solo devuelve un booleano, así que no filtra ninguna fila,
  y lleva `search_path` fijado para que no se pueda secuestrar.
- **`profiles` deja de ser enumerable.** Hoy `profiles.select('*')` lista a
  todos los usuarios de la instancia; con la política nueva solo se ven los
  perfiles con los que se comparte algún grupo.

### 4.-1 El estado real de producción, y por qué la migración es delicada

El inventario de solo lectura reveló dos cosas que cambian el plan:

**1. RLS ya está activa, pero no protege.** Las políticas existentes conceden
acceso global a `authenticated` con `using (true)` / `with check (true)`. Es
decir: **hoy, cualquier cuenta autenticada puede leer y escribir todos los
gastos, grupos y liquidaciones**, no solo los suyos. Con dos cuentas que
comparten todo, eso no ha tenido consecuencias; con una tercera cuenta, sí las
tendría.

Y hay una trampa al migrar: **todas las políticas PERMISSIVE se combinan con
OR**. Crear las políticas nuevas sin retirar las viejas no cierra nada — deja
la base con apariencia de protegida sin estarlo, que es peor que no migrar.
Por eso `0004` empieza retirando las políticas existentes de las cinco tablas
de gastos, enumerándolas del catálogo para que ninguna sobreviva por llamarse
como no esperábamos.

**2. La base la comparten dos aplicaciones.** Además de gastos, contiene
`viajes`, `viaje_diario`, `viaje_fotos`, la función `viajes_tocar()` y sus
políticas. Nada de eso puede tocarse. Por eso el borrado de políticas está
acotado a las cinco tablas de gastos y **nunca** se aplica al esquema `public`
entero, y por eso existe una prueba de frontera que compara columnas,
restricciones, índices, políticas, triggers, funciones, privilegios,
pertenencia a Realtime y número de filas de esas tres tablas antes y después
de migrar.

### 4.-0.5 Riesgo operativo: el alta de cuentas está ABIERTA

Configuración verificada en el panel de Supabase:

| Ajuste | Estado |
|---|---|
| **Allow new users to sign up** | **ACTIVADO** |
| Confirm email | activado |
| Proveedor Email | activado |
| Allow manual linking | desactivado |
| Allow anonymous sign-ins | desactivado |

**Hoy esto es un riesgo real.** Con las políticas históricas `using (true)`,
cualquiera que se registre —y cualquiera puede— obtiene acceso de lectura y
escritura a **todos** los gastos, grupos y liquidaciones. Solo lo mitiga que
haga falta confirmar el correo, y que nadie lo haya intentado.

**Después de aplicar `0004` deja de serlo.** Una cuenta nueva sin membresías
no ve ningún grupo, ningún gasto, ninguna liquidación ni ningún perfil salvo
el suyo. Está comprobado en CI con consultas reales: la aserción `[U03]` da de
alta a alguien y verifica que no accede a nada.

Es decir: **la migración de RLS es lo que cierra este riesgo**, no un ajuste
del panel. Cerrar el alta sería una medida adicional, no la solución.

Nada de esta configuración se ha cambiado desde el código, ni se cambiará: se
documenta y se comprueba su consecuencia.

### 4.0 Dos trampas de RLS que ya han mordido en este proyecto

Las dos aparecieron escribiendo estas políticas. Conviene tenerlas presentes
antes de tocar `0004_rls.sql`:

**1. Una subconsulta a una tabla protegida no dice «existe», dice «existe y yo
puedo verlo».** Una versión de `miembros_invitar` tenía una rama
`not exists (select 1 from group_members where group_id = ...)`. Para quien no
es miembro, esa subconsulta devuelve siempre vacío —porque RLS se la filtra—,
así que `not exists` era cierto para **cualquier grupo ajeno**: bypass de
autorización completo. **Nunca uses `not exists` sobre una tabla protegida para
decidir un permiso.**

**2. Una política no puede consultar su propia tabla.** Al expandir RLS,
PostgreSQL vuelve a entrar en la misma relación y aborta con
`infinite recursion detected in policy for relation ...`. Por eso las
comprobaciones de pertenencia y propiedad van por `es_miembro()` y `es_owner()`,
funciones `SECURITY DEFINER` que saltan RLS y devuelven un booleano, sin filtrar
ninguna fila.

Ambas están cubiertas: `99_comprobaciones.sql` falla si alguien reintroduce una
política de `group_members` que se consulte a sí misma, y `98_seguridad_dml.sql`
ejecuta el ataque de autoinvitación como aserción `D01`.

### 4.1 Cada consulta del frontend, contra la política que la autoriza

Toda operación que el cliente puede lanzar, y qué política la cubre. Es la
comprobación que hay que rehacer cada vez que se toque `0004_rls.sql`: una
operación sin política es la app rota, y una política de más es una fuga.

| Dónde | Operación | Política que la autoriza |
|---|---|---|
| `supabase-data.js:46` | `select('*')` sobre las 5 tablas | `profiles_leer`, `groups_leer_los_mios`, `miembros_leer`, `gastos_leer`, `liquidaciones_leer` |
| `supabase-data.js:132` | `groups.insert().select().single()` | `groups_crear` + `groups_leer_los_mios` **para el RETURNING** |
| `supabase-data.js:137` | `group_members.insert()` | `miembros_invitar` |
| `mutaciones.js:46` | `expenses/settlements.insert()` | `gastos_crear` / `liquidaciones_crear` |
| `mutaciones.js:106` | `update().eq('id').select('id')` | `gastos_modificar` (USING + CHECK) + la de SELECT |
| `mutaciones.js:167` | `delete().eq('id').select('id')` | `gastos_borrar` + la de SELECT |
| `offline-queue.js:239` | `upsert(onConflict:'client_id')` | `gastos_crear` **y** `gastos_modificar`: un upsert es `ON CONFLICT DO UPDATE` y necesita las dos |
| `offline-queue.js:253/270` | `update` / `delete` con `select('id')` | igual que las de `mutaciones.js` |
| `app.js:998/1002` | `delete().eq('group_id').like('client_id','imp:%')` | `gastos_borrar` / `liquidaciones_borrar` |
| `app.js:1113` | `upsert` por lotes de la importación | `gastos_crear` + `gastos_modificar` |
| `app.js:1221/1223` | `delete().eq('group_id')` (vaciar grupo) | `gastos_borrar` / `liquidaciones_borrar` |
| `app.js:1274` | `groups.update({name}).select('id')` | `groups_modificar` + la de SELECT |
| `app.js:1298` | `groups.delete().select('id')` | `groups_borrar` (solo `owner`) + la de SELECT |

Dos trampas que este repaso destapó y que ya están corregidas:

1. **`INSERT ... RETURNING` aplica la política de SELECT.** Y lo hace *antes*
   de que corran los triggers `AFTER INSERT`. El trigger que apunta al
   creador en `group_members` todavía no ha corrido cuando se evalúa el
   RETURNING, así que con una política de solo `es_miembro(id)` **crear un
   grupo habría fallado**. Por eso `groups_leer_los_mios` incluye
   `or created_by = auth.uid()`.
2. **Un `upsert` necesita política de UPDATE, no solo de INSERT.** La cola
   offline y la importación de CSV usan `upsert(onConflict:'client_id')`,
   que se traduce a `ON CONFLICT DO UPDATE`. Sin `gastos_modificar`,
   sincronizar la cola fallaría con un error de permisos.

`supabase/pruebas/99_comprobaciones.sql` comprueba la primera de las dos en
CI, para que no se pierda si alguien reescribe la política.

---

## 5. Lo que sí está implementado en esta fase (lado cliente)

Estas defensas están en el código y cubiertas por pruebas. Ninguna sustituye
a RLS: son la capa que evita que un fallo del servidor se convierta en
pérdida de datos o en un saldo falso.

| Qué | Dónde | Prueba |
|---|---|---|
| Un rechazo de RLS no se confunde con "sin conexión" ni entra en la cola | `js/errores.js`, `js/mutaciones.js` | `tests/mutaciones.test.js` |
| La cola offline está aislada por `user_id` y valida el dueño antes de enviar | `js/almacen.js`, `js/offline-queue.js` | `tests/offline-queue.test.js` |
| Una edición o borrado rechazado se deshace en pantalla | `js/mutaciones.js` | `tests/mutaciones.test.js` |
| Un `update`/`delete` que no afecta a ninguna fila no se da por bueno | `js/offline-queue.js`, `js/mutaciones.js` | `tests/offline-queue.test.js` |
| El saldo no se calcula sobre un conjunto truncado | `js/supabase-data.js` | `tests/datos.test.js` |
| No se calcula un saldo si no hay exactamente dos personas identificadas | `js/balances.js`, `js/miembros.js` | `tests/miembros.test.js` |
| El escapado de HTML cubre también las comillas | `js/html.js` | `tests/miembros.test.js` |
| El campo de importe no evalúa código | `js/dinero.js` | `tests/csv.test.js` |

### 5.1 XSS almacenado (corregido)

La versión anterior escapaba con `div.textContent = t; return div.innerHTML`,
que escapa `< > &` pero **no las comillas**, y el resultado se interpolaba
dentro de atributos:

```js
' data-color="' + escapar(quien.color) + '"'
```

Un `profiles.color` con el valor `laurel" onmouseover="…` inyectaba un
atributo en la pantalla de la otra persona del grupo. `js/html.js` escapa
ahora `& < > " ' \``.

### 5.2 Ejecución de expresiones (corregido)

`aNumero()` usaba `Function('return (' + entrada + ')')()` para resolver
sumas escritas en el campo de importe. La lista blanca de caracteres era
estrecha, pero es una construcción `eval` sobre entrada de usuario en el
camino de guardar un gasto. Se ha sustituido por un analizador aritmético
cerrado de unas 40 líneas.

### 5.3 Aislamiento del almacenamiento local (corregido)

Antes: `gastos.cache`, `gastos.cola`, `gastos.grupo` y `gastos.visita` eran
globales al navegador, y `salir()` solo borraba la primera. Una cola dejada
por A se enviaba con la sesión de B.

Ahora: `gastos.v2.<user_id>.<nombre>`, cada tarea con `owner_user_id`, que se
valida antes de enviar, y purga de los datos de otras cuentas al entrar.

---

## 6. Lo que sigue pendiente

| # | Pendiente | Bloquea |
|---|---|---|
| 1 | Comprobar si RLS está activa hoy | Todo lo demás |
| 2 | Aplicar `0002` + backfill | El aislamiento por grupo |
| 3 | Aplicar `0003` (índice único de `client_id`) | Evitar duplicación de gastos |
| 4 | Aplicar `0004` (políticas) | El aislamiento real |
| 5 | Decidir si el alta pública de cuentas debe seguir abierta | Que un desconocido pueda registrarse |
| 6 | Interfaz para invitar a alguien a un grupo | Que `group_members` sea usable sin SQL |

El punto 6 queda **fuera del alcance** de esta fase: hoy la aplicación es de
dos personas y el backfill las deja a las dos en todos los grupos. En cuanto
haya un tercer usuario hará falta una pantalla de invitación.

---

## 7. Cómo informar de un problema de seguridad

Es un proyecto personal de dos usuarios. Si encuentras algo, abre una
incidencia en el repositorio sin incluir datos reales ni tokens. Si el
problema permite acceder a datos de otra persona, escribe directamente a la
persona propietaria del repositorio antes de publicarlo.

---

## 8. Rotación de claves

Si la clave `service_role` o la contraseña de la base de datos se filtran:

1. *Project settings → API → Rotate* la clave afectada.
2. Cambiar la contraseña de la base de datos.
3. Revisar los registros de acceso del proyecto.
4. La clave `anon` **no** hace falta rotarla por estar publicada: es pública
   por diseño. Sí hace falta si se descubre que RLS estaba desactivada,
   porque entonces habrá que asumir que los datos han estado accesibles.

---

## Toda función nueva: la regla, y por qué hace falta

**PostgreSQL concede `EXECUTE` a `PUBLIC` sobre cada función que se crea**, y
`anon` lo hereda. Eso **no se puede desactivar** desde los privilegios por
defecto del esquema: comprobado que

```sql
alter default privileges in schema public revoke execute on functions from public;
```

**borra** la fila de `pg_default_acl` y devuelve el esquema al valor de serie,
que es precisamente esa concesión. La orden se acepta y no hace nada.

Por eso, **cada función nueva del proyecto lleva sus tres líneas**:

```sql
create function public.lo_que_sea(...) ... ;

revoke all on function public.lo_que_sea(...) from public, anon;
grant execute on function public.lo_que_sea(...) to authenticated;   -- solo si toca
```

El `grant` es deliberado y va uno por uno: exponer una función tiene que ser
una decisión, no un descuido. Así es exactamente como `trasladar_saldo` acabó
al alcance del rol anónimo — el incidente E12.

### Quién lo hace cumplir

`supabase/pruebas/106_ninguna_funcion_abierta.sql` recorre **todas** las
funciones de `public` y falla si alguna es ejecutable por `PUBLIC` o por
`anon`. Se ejecuta en dos sitios:

- en el **CI**, tras aplicar todas las migraciones;
- como **última puerta de `aplicar-migraciones.sh`**, así que un despliegue
  con una función abierta no se da por bueno.

La garantía no está en el esquema: está en esa comprobación. Es menos elegante
que un ajuste de configuración, pero es lo que de verdad se puede cumplir.

### Limitación residual, declarada

Una función creada **a mano** fuera de las migraciones —desde el editor SQL de
Supabase, por ejemplo— nacería abierta a `PUBLIC` hasta que `106` la detecte en
el siguiente despliegue o pase del CI. No bloquea nada porque las funciones de
esta aplicación se gestionan por migraciones, pero conviene saberlo: si alguien
crea una función a mano, tiene que escribir el `revoke` a mano también.

Se descartó a propósito un **event trigger** que revocara en cada
`CREATE FUNCTION`: necesita superusuario, cambia el comportamiento global de la
base y afectaría también a lo que cree la propia Supabase.
