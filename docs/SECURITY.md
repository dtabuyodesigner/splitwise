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
