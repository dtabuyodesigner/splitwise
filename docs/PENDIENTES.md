# Pendientes no bloqueantes

Mejoras detectadas durante la fase 1 que **no** invalidan el trabajo hecho y
que se han dejado documentadas en lugar de abordarlas. Ninguna bloqueó el cierre
de la fase 1, ni el de la fase 2, ni el de la fase 3.

Fases cerradas: la **2** el 25 de agosto de 2026 —ver
[`CIERRE-FASE-2.md`](CIERRE-FASE-2.md)— y la **3** el 26 de agosto de 2026 —ver
[`CIERRE-FASE-3.md`](CIERRE-FASE-3.md)—.

Orden: primero lo que más se parece a un fallo, luego lo cosmético.

---

## P2 · Correcciones pequeñas

### 1. `deshacerImportacion()` borra también lo que importó la otra persona

`js/app.js` → `deshacerImportacion()` ejecuta
`delete ... where group_id = X and client_id like 'imp:%'`. Eso alcanza a
todas las importaciones del grupo, no solo a la última ni solo a las
propias.

**Arreglo previsto:** guardar el lote de importación (por ejemplo,
`imp:<uuid-del-lote>:<huella>`) y borrar solo ese lote.
**Por qué no ahora:** cambia el formato del `client_id` y obliga a pensar la
compatibilidad con lo ya importado.

### 2. Dos CSV distintos pueden colisionar en el `client_id`

El `client_id` de una fila importada es
`imp:huella(grupo|línea|fecha|concepto|importe|pagador)`. Dos archivos
distintos cuya fila N coincida en esos seis campos producen la misma marca,
y el segundo sobrescribe al primero en lugar de añadirse.

Es el precio de que reimportar el mismo archivo sea idempotente, que es la
propiedad que se quería. Se arregla junto con el punto 1.

Ojo: esto es la colisión *semántica* (mismos datos → misma marca), que es
intencionada. La colisión de *hash* —datos distintos, misma marca— sí era un
fallo y está corregida: `huella()` era un djb2 de 32 bits con 7 colisiones
reales en 120.000 filas, y ahora son 128 bits con cero en 500.000.

### 2b. Un CSV importado antes de la v16 y reimportado después se duplicará

Al cambiar `huella()`, las filas importadas con la versión anterior tienen
un `client_id` que la nueva ya no reproduce. Reimportar **ese mismo archivo**
tras actualizar crearía una segunda copia en vez de reconocerla.

Solo afecta a quien reimporte un archivo antiguo. El botón **Borrar lo
importado** sigue funcionando (el prefijo `imp:` no ha cambiado), así que la
salida existe. No se ha añadido compatibilidad hacia atrás porque exigiría
calcular las dos huellas en cada fila y arrastrar el hash viejo
indefinidamente.

### 3. «solo para Pilar» en el dictado se entiende como «lo pagó Pilar»

`js/voice.js` busca al pagador **antes** que el reparto, así que en «libro 15
solo para Pilar» el nombre lo consume la detección de pagador y el reparto
se queda en «a medias».

**Arreglo previsto:** detectar el reparto antes que el pagador, o marcar los
fragmentos ya consumidos en vez de eliminarlos del texto.
**Por qué no ahora:** reordenar el analizador puede cambiar el resultado de
frases que hoy funcionan, y el dictado siempre se revisa antes de guardar.
Se corrigió sí el caso «solo para mí», que no casaba nunca por un `\b` que
no cierra tras una vocal acentuada.

### 4. La cola heredada se adopta bajo la cuenta que entra primero

`migrarDesdeEsquemaAntiguo()` asigna la cola antigua (sin dueño conocido) a
quien abre la app por primera vez con la versión nueva.

Es lo que la versión anterior habría hecho con esa misma cola, así que no
añade riesgo, y evita perder apuntes. Ocurre **una sola vez**. La alternativa
—descartarla— perdería trabajo real. La otra alternativa —preguntar— exige
una pantalla que esta fase no contempla.

### 5. Un usuario sin fila en `profiles` ve la app medio vacía

Antes, `repartirPerfiles()` caía a `perfiles[0]` si no encontraba el perfil
propio, lo que hacía que la app te mostrara como si fueras otra persona.
Ahora `estado.yo` queda a `null` y se ve el mensaje *"Tu perfil todavía no
está creado en la base de datos"*.

Es correcto pero seco. Falta un camino de recuperación: un botón que cree la
fila, o que explique que hay que confirmar el correo.

### 6. `expenses.category` no tiene restricción en el servidor

La lista de categorías vive solo en `js/config.js`. Un cliente modificado
podría escribir cualquier cadena, y la interfaz la enseñaría con el icono
genérico.

**Arreglo previsto:** un `CHECK` con la lista, o una tabla `categories`.
**Por qué no ahora:** hay que confirmar antes qué valores existen realmente
en producción; una categoría antigua no contemplada haría fallar la
migración.

---

## Seguridad · dos hallazgos cerrados en F0

Los detectó la auditoría previa al sistema de invitaciones, ejecutando
consultas reales contra una copia desechable. Los cierra
`0010_consentimiento_y_oraculo.sql`, y las pruebas de
`110_invitaciones.sql` fallan si se quita cualquiera de las tres piezas del
arreglo —se comprobó revirtiéndolas una a una—.

### H1 · Se podía meter a alguien en un grupo sin su consentimiento · **cerrado**

La política `miembros_invitar` exigía solo ser miembro, sin mirar QUÉ
`user_id` se insertaba: un `POST /rest/v1/group_members` metía a cualquiera
en tu grupo. La víctima veía de pronto un grupo al que nunca se apuntó, y su
perfil quedaba visible para desconocidos. No exponía sus gastos, pero es un
fallo de consentimiento, y habría dejado sin sentido el sistema de
invitaciones.

Tenía **dos puertas**, no una. La segunda apareció al implementar el arreglo:
`miembros_cambiar_rol` acotaba quién podía actualizar —el propietario— pero
no qué columnas, así que un `update group_members set user_id = '<víctima>'`
sustituía a un miembro por cualquier persona.

Cómo queda: la política de INSERT solo deja **apuntarse a uno mismo**, y solo
en un grupo que hayas creado tú. El UPDATE pasa a ser un privilegio **por
columnas**: `grant update (role)`, nada más. Entrar en un grupo por
invitación es competencia exclusiva de `aceptar_invitacion()`, que es
`SECURITY DEFINER` y no pasa por ninguna política.

Por qué el privilegio de columna y no una política: en un UPDATE, `using` ve
la fila antigua y `with check` la nueva, y ninguna expresión puede ver las
dos a la vez. «Y además `user_id` no ha cambiado» no se puede escribir con
RLS.

### H2 · `es_miembro()` y `es_owner()` eran un oráculo de pertenencia · **cerrado**

Están concedidas a `authenticated` porque las políticas las invocan, y eso
las convertía también en RPC llamables a mano. Respondían la verdad sobre
**cualquier** par (grupo, persona):

```
es_miembro('<grupo ajeno>', '<persona ajena>')  →  t
select * from groups                            →  0 filas
```

Gravedad baja —hacen falta dos UUID que no se adivinan, y `profiles_leer`
impide enumerarlos— pero era información sin ninguna razón de ser.

Cómo queda: solo responden sobre uno mismo, o sobre terceros cuando quien
pregunta ya pertenece a ese grupo, y entonces no dicen nada que
`miembros_leer` no enseñe ya. En cualquier otro caso devuelven `false`.

Se devuelve `false` y no una excepción a propósito: estas funciones viven
dentro de políticas RLS, y una excepción abortaría la consulta del usuario
legítimo en vez de filtrar una fila. Además `false` es el valor que la
política habría dado igualmente, así que **ninguna política cambia de
resultado**: las 41 aserciones de `98_seguridad_dml.sql` y las 19 de
`102_validar_0007.sql` siguen pasando sin tocar una línea.

---

## Pendientes que ha dejado F1

### 18. Cualquier MIEMBRO puede generar una invitación, no solo el propietario

Es lo que permitía la política que 0010 retiró, así que no amplía las
capacidades de nadie. Pero significa que un amigo al que Alba invita puede
traer a más gente a su grupo.

Restringirlo a `owner` es **una línea** de `crear_invitacion()`, marcada en el
propio archivo. **Conviene decidirlo antes de F2**, porque cambia lo que la
interfaz tiene que enseñar.

### 19. El token viaja como parámetro al aceptar

Al crearla, el token solo va en la RESPUESTA, así que no puede acabar en el
registro de sentencias. Al **aceptarla** sí es un parámetro de la llamada. Con
la configuración normal de Supabase eso no se registra, pero si alguna vez se
activara `log_statement = 'all'` los tokens quedarían en el registro.

Mitigación real: caducan a los 7 días y se pueden revocar.

### 20. No hay límite de invitaciones por grupo

Un miembro puede crear tantos enlaces como quiera. No es un problema de
seguridad —cada uno hay que compartirlo a mano— pero un límite razonable
(por ejemplo, 20 activas por grupo) evitaría que la lista se vuelva
inmanejable. Se puede añadir sin tocar el esquema.

### 21. `handle_new_user()` asigna `buganvilla` a todo el mundo menos al primero

El color se decide con `case when (select count(*) from profiles) = 0 then
'laurel' else 'buganvilla' end`. Con dos personas funcionaba; con Alba y sus
amigos, todos menos Dani serán del mismo color. Es cosmético, **pero
`0006_rls_viajes.sql` usa el color como criterio de identidad** en su
backfill, así que conviene revisarlo antes de que haya más cuentas.

---

## Peticiones de producto pendientes de la fase siguiente

Quedan estas dos, **separadas y sin implementar**. Ninguna depende de la
otra ni del traslado de saldo, que ya está resuelto.

### 0.c Mover un gasto entre grupos, como operación explícita

En esta fase **el grupo de un gasto es inmutable**: al crearlo sale del grupo
activo y al editarlo se conserva el suyo. El selector de grupo de la hoja se ha
retirado, porque permitía validar un grupo y escribir en otro.

Falta la operación explícita «mover este gasto a otro grupo», con su
confirmación y sus comprobaciones (que las personas implicadas pertenezcan al
grupo de destino, y que ese grupo admita el reparto del gasto).

**No confundir con «trasladar saldo»**, que es otra cosa:

| | Mover un gasto | Trasladar saldo |
|---|---|---|
| Qué cambia | **Dónde ocurrió el consumo** | Solo **la deuda pendiente** |
| El gasto histórico | Cambia de grupo | **Se queda intacto donde estaba** |
| Total gastado del grupo de origen | Baja | No cambia |
| Estadísticas por categoría | Se recalculan en los dos grupos | No cambian |
| Para qué sirve | Corregir un error: se apuntó en el grupo equivocado | Arrastrar lo que se debe al grupo que se está usando |

Trasladar saldo **ya está hecho** (§0). Mover un gasto **no**, y sigue siendo una
operación distinta: esta toca `expenses`, aquella no. Diseño del traslado en
[`DISENO-TRASLADO-SALDO.md`](DISENO-TRASLADO-SALDO.md).

### 0.a Grupos de más de dos personas

Regla de negocio confirmada: la pertenencia se define **grupo a grupo**. Habrá
grupos de dos, alguno con una tercera persona y alguno individual.

Ya implementado en esta fase: `group_members` es la fuente de verdad, un grupo
individual funciona, uno de dos se comporta como siempre, y **uno de tres o más
no calcula saldo** y lo dice en pantalla.

Pendiente: el motor de reparto multilateral (participaciones por gasto, balance
individual, simplificación de deudas). **Diseño en
[`HITO-GRUPOS-MULTIPERSONA.md`](HITO-GRUPOS-MULTIPERSONA.md)**, con la
comprobación de que el esquema actual no lo impide.

También pendiente: la interfaz de invitación explícita, que no puede basarse en
buscar usuarios porque `profiles_leer` impide enumerarlos a propósito.

El traslado de saldo **no lo desbloquea ni lo acerca**: solo funciona entre grupos
de dos con la misma pareja, y lo comprueba en el servidor.

## Resuelto en la fase 3

### 0. Trasladar saldo entre grupos — **resuelto, desplegado y verificado**

El enunciado que se registró como función pendiente independiente era:

> **Trasladar saldo entre grupos sin convertirlo en gasto ni alterar las
> estadísticas históricas.**

Está cumplido.

| | |
|---|---|
| Estado | **Resuelto, desplegado y verificado en producción** |
| Servidor | `0007_traslado_de_saldo.sql`, aplicada el 25 de agosto de 2026 y validada con 19 comprobaciones |
| Cliente | v17, servida por GitHub Pages desde `main` `88011b2` |
| Ejecutado de verdad | 26 de agosto de 2026 |
| Diseño | [`DISENO-TRASLADO-SALDO.md`](DISENO-TRASLADO-SALDO.md) |
| Acta | [`CIERRE-FASE-3.md`](CIERRE-FASE-3.md) |

El caso real que lo pedía —«en Slovenia Dani debe 225 € a Pilar, pero ahora usan
otro grupo y quiere llevarse la deuda allí»— se ha ejecutado sobre producción:

- Slovenia quedó a **0,00 €**;
- Bierzo & Asturias recibió la deuda, **156,09 €** a nombre de Dani;
- **ningún gasto se copió ni se movió.**

Se cumple la condición que lo definía: **no es un gasto por construcción.** Un
traslado son dos liquidaciones vinculadas a una fila de `balance_transfers`;
`expenses` no se toca, así que ni el total gastado ni las estadísticas por
categoría lo ven. El total gastado de Bierzo sí cambió ese día, pero **no por el
traslado**: fue al eliminar el apunte manual «Deuda Dani225,60», el apaño que el
traslado viene a sustituir. Está contado en [`CIERRE-FASE-3.md`](CIERRE-FASE-3.md).

**No confundir esto con los dos pendientes que siguen abiertos**, §0.a y §0.c:
son funciones distintas, no dependían de esta y siguen sin implementar.

---

---

## P2 · Interfaz

### 7. No hay forma de invitar a alguien a un grupo

`group_members` se rellena por SQL. Mientras la app sea de dos personas y el
backfill las meta a las dos en todo, no hace falta; en cuanto haya un tercer
usuario, sí.

### 8. Los apuntes rechazados se gestionan con un `confirm()`

La barra de estado, al pulsarla, enseña un `confirm()` con los primeros
cinco fallos y ofrece descartar o reintentar. Funciona, pero merece una hoja
propia con el detalle de cada apunte y la opción de corregirlo y reenviarlo.

### 9. El filtro por categoría no tiene interfaz

`estado.filtro.categoria` existe y `filtrarMovimientos()` lo aplica, pero no
hay ningún control que lo active. Ya era así antes. Los chips de la hoja de
estadísticas serían el sitio natural.

### 10. `TOPE_FIEL = 300` está fijo

La barra de la balanza satura a 300 €. En un viaje se satura enseguida y
deja de informar. Podría escalarse con el gasto del grupo.

---

## P2 · Infraestructura

### 11. Supabase JS se carga desde un CDN sin `integrity` ni respaldo

`js/app.js` importa `@supabase/supabase-js@2` desde `cdn.jsdelivr.net`. Sin
SRI (los módulos ES no admiten `integrity` en un `import`) y sin plan B si el
CDN cae. El service worker lo cachea tras la primera visita, así que el
problema es solo la primera carga.

**Arreglo previsto:** descargar el paquete al repositorio y servirlo desde el
mismo origen. Es la mejora de infraestructura con mejor relación
coste/beneficio de esta lista.

### 12. `styles.css` sigue teniendo 1018 líneas

Se ha extraído del HTML sin trocear. Dividirlo por bloques (fichas, saldo,
lista, hojas) sería el siguiente paso natural, pero mover CSS es donde más
fácil se cuela una regresión visual y no había forma de comprobarlo
automáticamente en esta fase.

### 13. No hay pruebas de interfaz

Todo lo probado es lógica pura o el trato con un Supabase falso. Un par de
recorridos con Playwright sobre `npm run servir` (entrar, apuntar un gasto,
comprobar el saldo) cubrirían el hueco.

### 14. CI no comprueba el CSS ni el HTML

`tools/verificar.mjs` comprueba versiones, referencias e iconos. No comprueba
que el HTML sea válido ni que el CSS no tenga reglas rotas.

### 15. Las migraciones no se han ejecutado contra ningún PostgreSQL real

Se ha añadido un trabajo de CI (`esquema`) que las aplica sobre un PostgreSQL
15 vacío y desechable con un sustituto de `auth`, comprueba el esquema
resultante y ejecuta `98_seguridad_dml.sql`, que suplanta usuarios y verifica
el aislamiento con consultas reales.

**Ese trabajo no se ha llegado a ejecutar** en esta sesión: en la máquina de
trabajo no había ni PostgreSQL ni Docker. Su primera ejecución será el primer
push a GitHub, y es lo primero que hay que mirar antes de tocar producción.

### 16. El trigger sobre `auth.users` puede no poder crearse

`0001` crea un trigger sobre `auth.users`, que pertenece a
`supabase_auth_admin`. Es el patrón que documenta la propia Supabase y suele
funcionar desde el editor SQL del panel, pero según cómo esté provisionado el
proyecto puede fallar con `must be owner of relation users`. CI no puede
detectarlo, porque allí la tabla la crea el propio rol de pruebas.

### 17. `es_miembro()` se evalúa una vez por fila en las consultas grandes

Las políticas llaman a `public.es_miembro(group_id)`, marcada `stable`, así
que PostgreSQL puede cachearla dentro de una misma consulta. Con el volumen
actual no es un problema, pero si algún día un grupo tiene decenas de miles
de gastos conviene medirlo con `explain (analyze, buffers)` y valorar
sustituirla por un `exists` correlacionado directo o un `IN` sobre una
subconsulta materializada.
