# Plan de migración de los datos existentes

La aplicación tiene datos reales en uso. Este plan está pensado para que
**ningún gasto se pierda y nadie deje de ver lo que ya veía**. Nada de lo
que hay aquí se ha ejecutado.

---

## 1. Punto de partida

Hoy no existe el concepto de "pertenencia a un grupo". La aplicación asume
que hay exactamente dos personas en toda la instancia y que ambas comparten
todo. Ese supuesto está en el código, no en la base de datos:

```js
estado.otro = estado.perfiles.find(p => p.id !== estado.yo?.id);
```

El objetivo de la migración es **convertir ese supuesto implícito en datos
explícitos**, sin cambiar quién ve qué.

## 2. Principio rector

> El estado después de la migración tiene que ser indistinguible del estado
> anterior **para las personas que ya usan la app**. Lo único que cambia es
> que ahora esa visibilidad está escrita en `group_members` y protegida por
> RLS, en vez de depender de que no exista una tercera cuenta.

---

## 3. Fases

### Fase 0 · Copia de seguridad (obligatoria)

```bash
supabase db dump --db-url "$URL_PRODUCCION" -f respaldo-$(date +%F-%H%M).sql
```

Comprueba que el archivo no está vacío y que contiene `COPY public.expenses`.
Guárdalo fuera del portátil. Además, desde la propia app, cada persona puede
pulsar **Copia de seguridad** y descargar su JSON: es una segunda red.

### Fase 1 · Frontend primero, base de datos después

Se despliega la rama `estabilizacion/fase-1` **sin aplicar ninguna
migración**. El frontend está escrito para funcionar en ambos mundos
(`supabase/README.md` §9). Esta fase ya aporta, por sí sola:

- los errores dejan de confundirse con el modo sin conexión,
- la cola offline queda aislada por cuenta,
- ediciones y borrados rechazados se deshacen en pantalla,
- el saldo deja de calcularse sobre un conjunto truncado.

**Deja pasar unos días en esta fase antes de seguir.** Si algo falla, la
marcha atrás es un `git revert`: la base de datos no se ha tocado.

### Fase 2 · Estructura sin efectos visibles

Aplicar `0001` y `0002` **sin el backfill**. A partir de aquí:

- existe la tabla `group_members`, vacía,
- los grupos nuevos registran automáticamente a quien los crea,
- todo lo demás sigue exactamente igual: el frontend ve `membresias: []`…

El frontend está preparado para esta ventana: `traerMembresias()` devuelve
`null` cuando la tabla existe pero está vacía, y con `null` se conserva el
comportamiento anterior. Así, dejar la tabla creada y vacía no esconde ningún
grupo. Aun así, conviene hacer las fases 2 y 3 seguidas.

### Fase 3 · Backfill

Antes de nada, ejecuta las consultas de `supabase/README.md` §4 y responde:

> ¿Hay algún grupo que solo deba ver una de las dos personas?

**Si la respuesta es NO** (el caso esperado: una pareja que comparte todo),
descomenta el backfill del final de `0002` y ejecútalo:

```sql
insert into public.group_members (group_id, user_id, role)
select g.id, p.id,
       case when g.created_by = p.id then 'owner' else 'member' end
from public.groups g
cross join public.profiles p
on conflict do nothing;
```

**Si la respuesta es SÍ**, no uses el `cross join`. Escribe las filas a mano:

```sql
insert into public.group_members (group_id, user_id, role) values
    ('<uuid-grupo-compartido>', '<uuid-A>', 'owner'),
    ('<uuid-grupo-compartido>', '<uuid-B>', 'member'),
    ('<uuid-grupo-solo-de-A>',  '<uuid-A>', 'owner')
on conflict do nothing;
```

Comprobación **obligatoria** antes de continuar:

```sql
-- Ningún grupo puede quedarse sin miembros: quedaría invisible para todos.
select g.id, g.name, count(m.user_id) as miembros
from public.groups g
left join public.group_members m on m.group_id = g.id
group by g.id, g.name
having count(m.user_id) = 0;
-- ↑ tiene que devolver CERO filas

-- Y nadie puede haber perdido acceso a un grupo en el que tiene gastos.
select distinct e.paid_by, e.group_id
from public.expenses e
where not exists (
    select 1 from public.group_members m
    where m.group_id = e.group_id and m.user_id = e.paid_by
);
-- ↑ tiene que devolver CERO filas
```

Si la segunda consulta devuelve algo, significa que alguien ha pagado gastos
en un grupo del que el backfill no le hace miembro. **Para y revisa el
backfill**: aplicar RLS en ese estado le ocultaría sus propios gastos.

### Fase 4 · Limpieza de datos previa a las restricciones

Ejecuta las consultas de `supabase/README.md` §5. Para cada una que devuelva
filas:

**Duplicados de `client_id`.** Se conserva la fila más antigua, que es la
que las dos personas han estado viendo:

```sql
-- Revisar primero qué se va a tocar.
select * from public.expenses
where client_id in (
    select client_id from public.expenses
    where client_id is not null group by client_id having count(*) > 1
)
order by client_id, created_at;

-- Y solo después, quitar el client_id a las copias posteriores.
-- No se borra ninguna fila: solo se les quita la marca de sincronización,
-- para que el índice único pueda crearse. Si alguna es un duplicado real,
-- se borra a mano desde la propia app.
update public.expenses e
set client_id = null
where exists (
    select 1 from public.expenses o
    where o.client_id = e.client_id and o.created_at < e.created_at
);
```

**Gastos huérfanos** (sin grupo o sin pagador). No se borran: se revisan uno
a uno. Suelen ser residuo de un borrado a medias.

**Importes que incumplen los `CHECK`.** No hace falta actuar: las
restricciones se crean `NOT VALID` y no afectan a lo existente. Se validan
más adelante, cuando esos datos se hayan corregido desde la app.

### Fase 5 · Restricciones e índices

Aplicar `0003`. El índice único sobre `client_id` es **lo que impide que la
cola offline duplique gastos**: es la sentencia más importante del archivo.

### Fase 6 · RLS

Aplicar `0004` siguiendo el procedimiento de validación de
`supabase/README.md` §6. Hazlo con la app abierta y las dos personas
disponibles para comprobar.

Justo después:

- ¿Ves tus grupos? ¿Los mismos que antes?
- ¿Ves los gastos de la otra persona en los grupos compartidos?
- ¿El saldo es el mismo número que antes de la migración? *(anótalo antes)*
- ¿Puedes apuntar un gasto nuevo?
- ¿Puedes editar y borrar uno tuyo?

Si algo falla, `supabase/README.md` §8 tiene la marcha atrás.

### Fase 7 · Realtime

Aplicar `0005`. Comprobar que un gasto apuntado en un móvil aparece en el
otro sin recargar.

---

## 4. Qué hacer con las colas offline pendientes durante la migración

Puede haber apuntes sin enviar en el móvil de alguien justo cuando se aplica
RLS. Con las políticas de `0004`, esos apuntes se aceptan siempre que quien
los envía sea miembro del grupo, y lo será si el backfill de la fase 3 es
correcto. Si alguno se rechaza, ya no se pierde en silencio: aparece en la
barra de estado como *"apunte rechazado por el servidor"* y se puede
reintentar o descartar desde ahí.

**Recomendación:** que las dos personas abran la app con conexión y esperen
a que la barra de estado desaparezca **antes** de empezar la fase 6.

---

## 5. Migración del almacenamiento local (automática)

No requiere ninguna acción. La primera vez que alguien abre la versión nueva:

1. Se crean las claves `gastos.v2.<user_id>.*`.
2. La cola antigua (`gastos.cola`), si tiene algo, se adopta bajo la cuenta
   que tiene la sesión abierta, y la app avisa con
   *"N apuntes pendientes de la versión anterior se han recuperado"*.
3. Se borran `gastos.cache`, `gastos.grupo` y `gastos.visita`: son datos
   derivados y se reconstruyen solos.

**Sobre el paso 2.** Adoptar la cola bajo la sesión activa es exactamente lo
que la versión anterior habría hecho con esa misma cola, así que no
introduce ningún riesgo nuevo, y evita perder apuntes que la persona ya daba
por guardados. Es una única vez: a partir de ahí el aislamiento por cuenta es
efectivo. Está anotado como pendiente no bloqueante en `docs/PENDIENTES.md`.

---

## 6. Cuándo dar la migración por buena

- [ ] Copia de seguridad hecha y verificada
- [ ] Ningún grupo con cero miembros
- [ ] Nadie con gastos en un grupo del que no es miembro
- [ ] Las dos personas ven los mismos grupos que antes
- [ ] El saldo de cada grupo coincide con el anotado antes de empezar
- [ ] Se puede crear, editar y borrar un gasto
- [ ] Un tercer usuario de prueba no ve absolutamente nada
- [ ] Realtime propaga los cambios entre los dos dispositivos
- [ ] La barra de estado está limpia en ambos móviles
