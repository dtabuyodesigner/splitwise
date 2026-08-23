# Diseño · Trasladar saldo entre grupos

> **Fase siguiente. No implementado.** Este documento existe para dejar el
> diseño acordado y para comprobar que el modelo `group_members` y las
> políticas RLS propuestas en `supabase/migrations/` **no impiden**
> implementarlo después. No se ha escrito ni una línea de código de esta
> función, y no debe escribirse mientras el CI de SQL y las políticas RLS
> sigan sin estar verdes.

## 1. Qué se quiere

En «Eslovenia», Dani debe 225 € a Pilar. Ahora usan «Ponferrada». Dani quiere
llevarse esa deuda al grupo que están usando.

Después de la operación:

- «Eslovenia» queda a 0,00 €.
- En «Ponferrada» consta que Dani debe 225 € a Pilar.
- Los gastos originales de «Eslovenia» **siguen intactos**.
- No se copia ni se mueve ningún gasto histórico.
- Solo se traslada el saldo pendiente.

## 2. Por qué no puede ser un gasto

Registrarlo como gasto ordinario en el destino duplicaría el **total gastado**,
las **estadísticas por categoría** y los **informes históricos**: ese dinero ya
se gastó en el grupo de origen y ya está contado allí. Es una **transferencia
de deuda**, no consumo nuevo.

## 3. Cómo encaja en el modelo actual

La buena noticia es que **el modelo no necesita cambiar de forma**, solo
crecer. `settlements` ya codifica la dirección de la deuda con `from_user` y
`to_user`, y `js/balances.js` la interpreta así:

```js
if (l.from_user === yoId && l.to_user === otroId) centimos += importe;
else if (l.from_user === otroId && l.to_user === yoId) centimos -= importe;
```

De ahí salen los dos movimientos:

| Grupo | Fila en `settlements` | Efecto sobre el saldo de Dani |
|---|---|---|
| **Origen** (Eslovenia) | `from_user = Dani`, `to_user = Pilar`, `amount = 225` | `+225` → el saldo queda en 0,00 € |
| **Destino** (Ponferrada) | `from_user = Pilar`, `to_user = Dani`, `amount = 225` | `−225` → Dani pasa a deber 225 € |

La fila del destino va **en dirección inversa** a propósito: es lo que crea la
deuda. Por eso hace falta marcarla, o la lista de movimientos diría «Pago de
Pilar a Dani», que es justo lo contrario de lo que ha pasado.

### Deudas en dirección contraria

Si en «Ponferrada» Pilar ya debía 50 € a Dani, el movimiento nuevo se suma al
saldo existente sin ningún tratamiento especial: `−225 + 50 = −175`, es decir
**Dani debe 175 € a Pilar**. Los dos movimientos se conservan por separado
para poder auditarlos; la interfaz enseña el neto.

## 4. Cambios de esquema necesarios

Una migración futura (`0006_traslado_de_saldo.sql`) con:

```sql
create table public.balance_transfers (
    id               uuid primary key default gen_random_uuid(),
    grupo_origen     uuid not null references public.groups(id)   on delete cascade,
    grupo_destino    uuid not null references public.groups(id)   on delete cascade,
    deudor           uuid not null references public.profiles(id),
    acreedor         uuid not null references public.profiles(id),
    importe          numeric(12,2) not null,
    fecha            date not null default current_date,
    creado_por       uuid not null references public.profiles(id),
    created_at       timestamptz not null default now(),
    idempotency_key  text not null,
    revertido_en     timestamptz,
    revertido_por    uuid references public.profiles(id),

    constraint ck_transfer_grupos_distintos check (grupo_origen <> grupo_destino),
    constraint ck_transfer_personas_distintas check (deudor <> acreedor),
    constraint ck_transfer_importe_positivo check (importe > 0)
);

create unique index uq_transfer_idempotency
    on public.balance_transfers (idempotency_key);

-- Vincula cada liquidación con su transferencia y dice qué papel juega.
alter table public.settlements
    add column if not exists transfer_id   uuid references public.balance_transfers(id) on delete set null,
    add column if not exists transfer_role text
        check (transfer_role in ('origen', 'destino', 'reversion_origen', 'reversion_destino'));

create index if not exists idx_settlements_transfer
    on public.settlements (transfer_id);
```

`transfer_role` es lo que permite a la interfaz enseñar
«Saldo trasladado a Ponferrada» / «Saldo procedente de Eslovenia» en lugar de
un pago normal, y lo que permite excluir estos movimientos de donde no deben
contar.

## 5. La operación, en el servidor

Dos peticiones independientes desde el navegador **no sirven**: si la segunda
falla, el origen queda saldado y la deuda no aparece en ningún sitio. Tiene que
ser una sola llamada transaccional.

```sql
create or replace function public.trasladar_saldo(
    p_grupo_origen  uuid,
    p_grupo_destino uuid,
    p_idempotency_key text
) returns public.balance_transfers
language plpgsql
security invoker          -- RLS sigue aplicando: es la red de seguridad
set search_path = public
as $$ ... $$;
```

Pasos, en este orden:

1. `v_actor := auth.uid()`; si es nulo, error de sesión.
2. **Idempotencia primero.** Si ya existe una fila con esa
   `idempotency_key`, devolverla y no hacer nada más. Es lo que hace que un
   reintento por mala conexión no traslade dos veces.
3. **Autorización.** `es_miembro(origen, actor)` y `es_miembro(destino, actor)`.
4. **Serialización.** `pg_advisory_xact_lock` sobre los dos `group_id`,
   tomados siempre en el mismo orden para no provocar interbloqueos. Sin esto,
   dos traslados simultáneos del mismo grupo podrían llevarse el saldo dos
   veces.
5. **Calcular el saldo en el servidor**, leyendo `expenses` y `settlements` del
   grupo de origen. **Nunca aceptar el importe que envía el navegador.**
6. Si el saldo es 0, no hay nada que trasladar: error explicativo.
7. Identificar deudor y acreedor a partir del signo.
8. Comprobar que **deudor y acreedor son miembros del grupo de destino**.
9. Insertar la fila de `balance_transfers`.
10. Insertar las **dos** liquidaciones vinculadas, con su `transfer_id` y su
    `transfer_role`.
11. Devolver la transferencia completa.

Todo dentro de la misma transacción: o se crean las dos liquidaciones, o no se
crea ninguna. Nunca puede quedar el origen saldado sin la deuda en destino, ni
al revés.

`security invoker` a propósito: así RLS sigue evaluándose y la función no puede
convertirse en una puerta trasera. Las comprobaciones explícitas del paso 3 y 8
están para dar un mensaje claro, no para sustituir a RLS.

### Reversión

```sql
create or replace function public.revertir_traslado(p_transfer_id uuid)
returns public.balance_transfers
```

- Solo si la transferencia existe y **no está ya revertida**.
- Solo si **las dos liquidaciones vinculadas siguen existiendo**.
- **No borra nada.** Inserta dos liquidaciones compensatorias con
  `transfer_role` `reversion_origen` / `reversion_destino`, y marca
  `revertido_en` / `revertido_por`.
- Los gastos históricos no se tocan en ningún caso.

Compensar en lugar de borrar deja el rastro completo de lo que pasó, que es lo
que se pide.

## 6. Interfaz

1. El usuario abre un grupo con saldo pendiente.
2. Pulsa **«Trasladar saldo»**.
3. La app enseña: importe exacto, quién debe, quién cobra, grupo de origen y
   selector de destino.
4. En el selector **solo aparecen grupos donde estén las dos personas**.
5. Confirmación explícita.
6. Una sola llamada RPC con una `idempotency_key` generada en el cliente
   (`crypto.randomUUID()`), reutilizada si hay que reintentar.

En la lista de movimientos, los dos apuntes se ven con concepto propio y con
un icono distinto del de un pago normal.

## 7. Compatibilidad con las políticas RLS propuestas — **comprobado**

Esta es la razón principal de escribir el documento ahora. Repaso de si algo
del modelo propuesto impediría implementarlo después:

| Necesidad de la función | ¿Lo permite el modelo propuesto? |
|---|---|
| Leer los gastos y liquidaciones del grupo de origen para calcular el saldo | Sí: `gastos_leer` y `liquidaciones_leer` con `es_miembro(group_id)` |
| Insertar la liquidación en el origen | Sí: `liquidaciones_crear` exige `es_miembro(group_id)` y que ambas partes sean miembros |
| Insertar la liquidación **inversa** en el destino | Sí: la política no mira la dirección, solo que `from_user` y `to_user` sean miembros del grupo |
| Exigir que las dos personas estén en los dos grupos | Sí, y **la política ya lo impone por sí sola**: `es_miembro(group_id, from_user)` y `es_miembro(group_id, to_user)` |
| Saber en qué grupos están ambas personas, para el selector | Sí: `group_members` con `miembros_leer` |
| Impedir que un intruso traslade saldos | Sí: sin membresía, `es_miembro` es falso en origen y destino |

**Conclusión: nada del modelo propuesto bloquea esta función.** Al contrario,
`group_members` es justo lo que hace posible la condición «solo grupos donde
estén las dos personas», que hoy no se podría comprobar porque no existe el
dato.

Lo único que hará falta en la migración futura es una política para
`balance_transfers` (leer y crear si eres miembro de los dos grupos) y ampliar
`liquidaciones_modificar` para que **no se puedan editar a mano** las
liquidaciones que tengan `transfer_id`: deben cambiarse solo por reversión.

## 8. Pruebas obligatorias antes de darlo por hecho

- Trasladar 225 € de Eslovenia a Ponferrada.
- El origen queda exactamente en 0,00 €.
- El destino aumenta la deuda exactamente en 225 €.
- Se conserva quién debe a quién.
- **Los totales de gastos de ambos grupos no cambian.**
- **Las estadísticas por categoría no cambian.**
- Un reintento con la misma `idempotency_key` no duplica nada.
- Un intruso no puede trasladar saldos.
- No se puede trasladar a un grupo donde falte una de las dos personas.
- Un error intermedio revierte la operación entera.
- Dos intentos concurrentes no trasladan dos veces el mismo saldo.
- La reversión restaura los dos saldos.
- Funciona cuando la deuda del destino va en dirección contraria
  (225 € y 50 € en sentidos opuestos → 175 €).

## 9. Fuera del alcance de la primera versión

- **Traslado parcial.** La v1 traslada siempre el saldo completo, que es lo que
  hace verificable el cálculo en el servidor. El parcial exige decidir qué pasa
  con el resto y puede esperar.
- Trasladar entre grupos con más de dos personas: hoy la interfaz es de pares.
