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

### Fase 3 · Backfill explícito, grupo por grupo

> **No existe un backfill automático, y es deliberado.**
>
> La regla de negocio es que la pertenencia se define grupo a grupo: habrá
> grupos de dos personas, alguno con una tercera y alguno individual.
> Cualquier regla automática se equivoca en cuanto aparece la excepción, y
> equivocarse aquí significa **dar acceso a los gastos de alguien a quien no
> le corresponden**, o **dejar a una persona fuera de un grupo que sí es
> suyo**.

Una versión anterior de este plan proponía `groups cross join profiles`. **Se
ha retirado.** Convertiría todos los grupos en compartidos por todas las
cuentas.

#### 3.1 Inventario, solo lectura

Ejecuta esto y revisa el resultado. Es de solo lectura y sale anonimizado, así
que se puede pegar en una conversación sin exponer correos:

```sql
with gente as (
    select id, 'Perfil ' || row_number() over (order by created_at) as alias
    from public.profiles
)
select
    g.name                                              as grupo,
    to_char(g.created_at, 'YYYY-MM-DD')                 as creado,
    count(distinct e.id)                                as gastos,
    coalesce(string_agg(distinct gente.alias, ', '), '—') as han_pagado,
    coalesce((select string_agg(distinct h.alias, ', ')
              from public.settlements s
              join gente h on h.id in (s.from_user, s.to_user)
              where s.group_id = g.id), '—')            as han_liquidado
from public.groups g
left join public.expenses e on e.group_id = g.id
left join gente on gente.id = e.paid_by
group by g.id, g.name, g.created_at
order by g.created_at;
```

#### 3.2 Decisión de Dani — **confirmada**

| Grupo | Gastos | Liquid. | Miembros | Propietarios |
|---|---|---|---|---|
| Casa | 0 | 0 | Dani y Pilar | **los dos** |
| Slovenia | 51 | 1 | Dani y Pilar | **los dos** |
| Bierzo & Asturias | 2 | 0 | Dani y Pilar | **los dos** |

Identidad verificada por consulta de solo lectura: **dos perfiles**, ambos con
nombre y con color, y **colores distintos**. `laurel` es Dani y es el perfil
más antiguo; `buganvilla` es Pilar.

Los dos como propietarios porque `groups.created_by` no existía antes de
`0001`: no hay forma de saber quién creó cada grupo, y es preferible eso a que
alguno se quede sin nadie que pueda administrarlo. **Es una decisión de
migración histórica, no el comportamiento futuro.**

**Casa era el caso sin red.** Sin gastos ni liquidaciones, no había nada en la
base de datos que apuntara en ninguna dirección: las guardas del backfill
detectan un grupo sin miembros o sin propietario, pero no pueden detectar un
miembro *de más*. Lo ha decidido Dani.

#### 3.3 Escribir el backfill#### 3.3 Escribir el backfill#### 3.3 Escribir el backfill

Rellena el PASO 2 de `supabase/migrations/0002b_backfill_pertenencia.sql` con
una línea por persona y grupo.

Si Dani confirma que **solo existen las dos cuentas** y que **todos los grupos
históricos son comunes**, el backfill puede añadir a las dos a todos ellos.
Incluso en ese caso:

- uno de los dos debe quedar como `owner`, **o los dos** si no se puede
  determinar con seguridad quién creó cada grupo;
- eso es una **migración histórica y nada más**. No es el comportamiento de
  los grupos futuros: a partir de aquí, crear un grupo mete únicamente a su
  creador y todo lo demás va por invitación explícita.

#### 3.4 Aplicar 0002 y 0002b **en la misma transacción**

Entre uno y otro, `group_members` existe pero está vacía. Como la pertenencia
es la fuente de verdad, en ese instante **nadie vería ningún grupo**. Por eso
van juntos o no van:

```bash
psql "$URL" -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/0002_group_members.sql \
  -f supabase/migrations/0002b_backfill_pertenencia.sql
```

`0002b` termina con cuatro comprobaciones que **deshacen la transacción entera**
si algo no cuadra:

1. ningún grupo se queda sin miembros;
2. ningún grupo se queda sin propietario;
3. todo `paid_by` pertenece a su grupo;
4. todo `from_user` y `to_user` pertenece a su grupo.

**No se puede aplicar `0004` (RLS) hasta que las cuatro pasen.** Si un pagador
no es miembro de su grupo, al activar RLS esa persona perdería el acceso a sus
propios gastos.

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
