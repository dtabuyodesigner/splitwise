# Pendientes no bloqueantes

Mejoras detectadas durante la fase 1 que **no** invalidan el trabajo hecho y
que se han dejado documentadas en lugar de abordarlas. Ninguna bloquea el
cierre de esta fase.

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

## Peticiones de producto pendientes de la fase siguiente

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

### 0. Trasladar saldo entre grupos

Pedido por Dani. Ejemplo real: en «Eslovenia» Dani debe 225 € a Pilar, pero
ahora usan «Ponferrada» y quiere llevarse la deuda allí. Después: «Eslovenia»
a 0,00 €, «Ponferrada» con los 225 € a nombre de Dani, y **los gastos
originales intactos** — no se copia ni se mueve ningún gasto.

No puede modelarse como un gasto: duplicaría el total gastado, las
estadísticas por categoría y los informes. Es una transferencia de deuda.

**Diseño completo en [`DISENO-TRASLADO-SALDO.md`](DISENO-TRASLADO-SALDO.md).**

Estado: **diseñado, no implementado.** No debe implementarse mientras el CI de
SQL y las políticas RLS sigan sin estar verdes. Ya está comprobado que el
modelo `group_members` y las políticas propuestas **no impiden** implementarlo
después; de hecho `group_members` es lo que hace posible la condición «solo
grupos donde estén las dos personas», que hoy no se podría comprobar.

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
