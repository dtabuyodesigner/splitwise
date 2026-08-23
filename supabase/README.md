# Supabase: cómo validar estas migraciones antes de tocar nada

> **Ninguna de las migraciones de `supabase/migrations/` se ha aplicado.**
> No se ha ejecutado ni una sola sentencia contra el proyecto de producción
> (`cmkzcvfjgrgxwqjimtxa.supabase.co`). Tampoco se ha leído su esquema: el
> servidor MCP de Supabase de la sesión de trabajo requería autenticación
> interactiva y no estaba disponible.
>
> Lo que hay aquí es una **propuesta versionada**, escrita a partir del
> código del frontend y del README original. Antes de aplicarla en
> producción hay que recorrer este documento entero.

---

## 1. Qué hace cada archivo

| Archivo | Qué hace | Riesgo |
|---|---|---|
| `0001_baseline_esquema.sql` | Deja el esquema por escrito. Todo `IF NOT EXISTS`. Añade el trigger que crea `profiles` al registrarse. | Bajo. En producción casi todo será no-op. Ojo con el trigger si ya existe otro equivalente. |
| `0002_group_members.sql` | Crea `group_members`, la función `es_miembro()` y los triggers de creación de grupo. El **backfill está comentado**. | Medio. El backfill decide quién ve qué. |
| `0003_restricciones_indices.sql` | Unicidad de `client_id`, claves foráneas, `CHECK` y los índices que hacen viable la paginación completa. | **Alto**: puede fallar si los datos actuales incumplen algo. Es deliberado. |
| `0004_rls.sql` | Activa RLS y crea todas las políticas. | **El más alto**. Mal aplicado, la app se queda en blanco. |
| `0005_realtime.sql` | Publicación de Realtime y `replica identity full`. | Bajo. |

`supabase/pruebas/` contiene un sustituto mínimo de lo que Supabase añade a
PostgreSQL y un juego de comprobaciones del esquema resultante. Se usan solo
en CI, sobre una base vacía. **No los ejecutes contra una base real.**

---

## 1.b Lo que CI comprueba, y lo que no

El trabajo `esquema` del workflow de CI aplica las cinco migraciones sobre un
**PostgreSQL 15 vacío y desechable** con un sustituto del esquema `auth`,
comprueba el esquema resultante, ejecuta `98_seguridad_dml.sql` (32 aserciones
suplantando usuarios reales) y reaplica las migraciones para comprobar que son
idempotentes. El resultado se publica como comentario del PR.

**Lo que eso demuestra:** que el SQL compila, que las políticas se crean, que
un usuario ajeno no puede leer ni escribir en un grupo del que no es miembro, y
que los invariantes del propietario se cumplen.

**Lo que NO demuestra:**

- Que la migración funcione **sobre los datos que ya existen**. La base de CI
  está vacía. Un `client_id` duplicado, un gasto huérfano o un grupo sin
  miembros solo aparecen con datos reales.
- Que el trigger sobre `auth.users` se pueda crear en el proyecto real: en CI
  esa tabla la crea el propio rol de pruebas, así que nunca falla por
  propiedad.
- Que las políticas actuales de producción sean compatibles: siguen sin
  inspeccionarse.

Por eso el CI en verde **no sustituye** al procedimiento de validación en local
con una copia de los datos que describe la sección 3.

> **Nota sobre el versionado.** Las migraciones `0002` y `0004` se han editado
> en el sitio durante esta fase, en lugar de añadir migraciones correctivas.
> Es deliberado y seguro: **ninguna se ha aplicado a ninguna base**, así que no
> hay ningún entorno donde la versión antigua ya haya corrido. A partir del
> momento en que se aplique alguna en un entorno real, este conjunto pasa a ser
> de solo lectura y cualquier corrección tendrá que ir en una migración nueva.

---

## 2. Orden obligatorio

```
0001 → 0002 → (backfill de 0002, revisado) → 0003 → 0004 → 0005
```

`0004` depende de que `group_members` esté poblada. Si se aplica antes del
backfill, **todos los grupos desaparecen para todo el mundo**, porque nadie
será miembro de nada.

---

## 3. Validar primero en local

Con la [CLI de Supabase](https://supabase.com/docs/guides/local-development):

```bash
# 1. Arrancar un Supabase local (Docker). No toca nada remoto.
supabase init          # solo la primera vez
supabase start

# 2. Traer una copia del esquema y de los datos de producción.
#    --data-only por separado para poder revisar el volcado antes de cargarlo.
supabase db dump --db-url "$URL_PRODUCCION" --schema public   -f /tmp/esquema.sql
supabase db dump --db-url "$URL_PRODUCCION" --schema public --data-only -f /tmp/datos.sql

# 3. Cargar esa copia en el local.
psql "$URL_LOCAL" -f /tmp/esquema.sql
psql "$URL_LOCAL" -f /tmp/datos.sql

# 4. Aplicar las migraciones, una a una, mirando el resultado.
for f in supabase/migrations/*.sql; do
  echo "── $f"
  psql "$URL_LOCAL" -v ON_ERROR_STOP=1 -f "$f"
done

# 5. Comprobar el esquema resultante.
psql "$URL_LOCAL" -f supabase/pruebas/99_comprobaciones.sql
```

`$URL_PRODUCCION` es la cadena de conexión de *Project settings → Database*.
El volcado es una operación de **solo lectura**.

Sin la CLI de Supabase basta un PostgreSQL 15 vacío más
`supabase/pruebas/00_stub_supabase.sql`, que es exactamente lo que hace CI.

---

## 4. Consultas que hay que ejecutar ANTES de decidir el backfill

Todas son de solo lectura. Ejecútalas en el SQL Editor de Supabase.

```sql
-- 4.1 ¿Está RLS activa hoy? (la pregunta principal sin responder)
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;

-- 4.2 ¿Qué políticas hay hoy, si es que hay alguna?
select tablename, policyname, cmd, roles,
       pg_get_expr(polqual, polrelid)      as usando,
       pg_get_expr(polwithcheck, polrelid) as con_check
from pg_policies
join pg_policy on pg_policy.polname = pg_policies.policyname
where schemaname = 'public';

-- 4.3 ¿Cuánta gente y cuántos grupos hay?
select (select count(*) from public.profiles) as perfiles,
       (select count(*) from public.groups)   as grupos,
       (select count(*) from public.expenses) as gastos,
       (select count(*) from public.settlements) as liquidaciones;

-- 4.4 ¿Quién ha pagado en cada grupo? Esto revela si algún grupo es
--     realmente de una sola persona.
select g.id, g.name,
       count(distinct e.paid_by) as personas_que_han_pagado,
       count(e.id)               as gastos
from public.groups g
left join public.expenses e on e.group_id = g.id
group by g.id, g.name
order by g.name;
```

**La pregunta que hay que responder con 4.4:** ¿hay algún grupo que solo
debería ver una de las dos personas? Si la respuesta es que no —todos los
grupos son comunes—, el backfill comentado al final de `0002` es correcto y
se puede descomentar. Si la respuesta es que sí, hay que sustituirlo por un
`insert` explícito grupo a grupo.

---

## 5. Consultas que hay que ejecutar ANTES de `0003`

Cada una debe devolver **cero filas**. Si alguna devuelve algo, hay que
limpiar los datos antes (ver `docs/PLAN-MIGRACION-DATOS.md`).

```sql
-- 5.1 Duplicados de client_id → impedirían el índice único
select 'expenses' as tabla, client_id, count(*) from public.expenses
where client_id is not null group by client_id having count(*) > 1
union all
select 'settlements', client_id, count(*) from public.settlements
where client_id is not null group by client_id having count(*) > 1;

-- 5.2 Gastos huérfanos → impedirían la clave foránea
select count(*) from public.expenses e
left join public.groups g on g.id = e.group_id where g.id is null;

select count(*) from public.expenses e
left join public.profiles p on p.id = e.paid_by where p.id is null;

select count(*) from public.settlements s
left join public.groups g on g.id = s.group_id where g.id is null;

-- 5.3 Importes que incumplirían los CHECK
select count(*) from public.expenses where amount <= 0;
select count(*) from public.expenses where payer_share < 0 or payer_share > 1;
select count(*) from public.settlements where amount <= 0;
select count(*) from public.settlements where from_user = to_user;
```

Los `CHECK` se añaden como `NOT VALID`, así que la migración **no fallará**
aunque haya filas antiguas que los incumplan: solo se aplicarán a lo nuevo.
Cuando 5.3 dé cero en todo, se validan a mano con las sentencias que hay
comentadas al final de `0003`.

---

## 6. Validar `0004` (RLS) antes de aplicarla en producción

En el entorno local, con la copia de los datos cargada:

```sql
-- Ponerse en la piel de un usuario concreto.
set local role authenticated;
set local request.jwt.claims = '{"sub":"UUID-DE-LA-PERSONA-A"}';

select count(*) from public.groups;      -- solo sus grupos
select count(*) from public.expenses;    -- solo los gastos de sus grupos
select count(*) from public.profiles;    -- ella + quien comparta grupo

-- Y ahora la otra persona.
set local request.jwt.claims = '{"sub":"UUID-DE-LA-PERSONA-B"}';
select count(*) from public.groups;

-- Y alguien que no es miembro de nada: debe ver cero de todo.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
select count(*) from public.groups, public.expenses, public.settlements;

reset role;
```

**Criterio de aceptación:** A y B siguen viendo exactamente lo mismo que
veían antes de la migración, y un tercero no ve absolutamente nada.

Después, con la app apuntando al Supabase local:

```bash
npm run servir     # http://localhost:8080
```

Cambia `SUPABASE_URL` y `SUPABASE_ANON_KEY` en `js/config.js` por los que
imprime `supabase start`, entra con las dos cuentas y comprueba a mano:
crear grupo, apuntar gasto, editar, borrar, saldar, importar CSV.

---

## 7. Aplicar en producción

Solo cuando todo lo anterior haya pasado:

```bash
# 1. Copia de seguridad completa y verificada.
supabase db dump --db-url "$URL_PRODUCCION" -f respaldo-$(date +%F-%H%M).sql
ls -la respaldo-*.sql       # que no esté vacío

# 2. Una migración cada vez, comprobando entre una y otra.
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/migrations/0001_baseline_esquema.sql
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/migrations/0002_group_members.sql
#    → descomentar y ejecutar el backfill; comprobar que ningún grupo
#      se queda con 0 miembros ANTES de seguir.
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/migrations/0003_restricciones_indices.sql
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/migrations/0004_rls.sql
psql "$URL_PRODUCCION" -v ON_ERROR_STOP=1 -f supabase/migrations/0005_realtime.sql
```

Hazlo en un momento en el que nadie esté usando la app, y ten la app abierta
en otra pestaña para comprobar después de cada paso.

---

## 8. Marcha atrás

Si tras `0004` la app se queda en blanco, lo que restablece el acceso al
instante es desactivar RLS. Es una medida de emergencia: deja los datos
abiertos a cualquier usuario autenticado, así que solo vale para ganar
tiempo mientras se arregla la política.

```sql
alter table public.profiles      disable row level security;
alter table public.groups        disable row level security;
alter table public.group_members disable row level security;
alter table public.expenses      disable row level security;
alter table public.settlements   disable row level security;
```

Para deshacer `0003`:

```sql
drop index if exists public.uq_expenses_client_id;
drop index if exists public.uq_settlements_client_id;
alter table public.expenses    drop constraint if exists fk_expenses_group;
alter table public.expenses    drop constraint if exists fk_expenses_payer;
alter table public.settlements drop constraint if exists fk_settlements_group;
alter table public.settlements drop constraint if exists fk_settlements_from;
alter table public.settlements drop constraint if exists fk_settlements_to;
alter table public.expenses    drop constraint if exists ck_expenses_importe_positivo;
alter table public.expenses    drop constraint if exists ck_expenses_reparto;
alter table public.settlements drop constraint if exists ck_settlements_importe_positivo;
alter table public.settlements drop constraint if exists ck_settlements_personas_distintas;
```

Ninguna de estas sentencias borra datos.

---

## 9. Compatibilidad del frontend durante la transición

El frontend de esta rama funciona **antes y después** de aplicar las
migraciones, sin cambios:

- `js/supabase-data.js` pide `group_members` y, si la tabla no existe
  (`42P01`), sigue adelante con `membresias: null`.
- `js/miembros.js` cae a la heurística de siempre cuando `membresias` es
  `null`, y pasa a resolver la pertenencia por grupo en cuanto hay datos.
- `crearGrupo()` intenta registrar la pertenencia y tolera que la tabla no
  esté todavía.

Es decir: se puede desplegar el frontend primero y aplicar las migraciones
después, sin ventana de indisponibilidad.
