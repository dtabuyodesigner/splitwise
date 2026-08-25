# Hito posterior · Grupos de más de dos personas

> **No implementado, y no debe implementarse dentro de la estabilización.**
> Este documento registra el requisito y comprueba que el esquema actual **no
> lo impide**.

## 1. Qué hace hoy la aplicación

La interfaz y `calcularSaldo()` están hechos para **exactamente dos personas**.
El reparto de un gasto se guarda en una sola columna:

```
expenses.payer_share  numeric(5,4)   -- fracción que asume QUIEN PAGÓ
```

Eso solo puede expresar un reparto entre dos: quien paga asume `payer_share` y
«el otro» asume el resto. Con tres personas la columna no da para más.

Por eso, en esta fase:

| Miembros del grupo | Comportamiento |
|---|---|
| **1** | Funciona. Se apuntan gastos, el reparto se fija al 100 % de quien los apunta y no hay saldo que enseñar. |
| **2** | Funciona igual que siempre. |
| **3 o más** | **No se calcula saldo.** Se ven los gastos y los totales, y la interfaz avisa: *«Este grupo tiene más de dos participantes; el reparto múltiple todavía no está disponible.»* |

La regla que no se rompe nunca: **antes que una cifra dudosa, ninguna cifra.**

## 2. Qué hará falta

1. **Gastos repartidos entre todos o entre participantes seleccionados.** No
   siempre participan todos los miembros en todos los gastos.
2. **Reparto por partes, porcentajes o cantidades exactas.** «A partes
   iguales», «60/25/15», «Ana 30 €, el resto entre los demás».
3. **Balance individual de cada integrante**, no un único número por grupo.
4. **Simplificación de deudas**: si A debe a B y B debe a C, reducir el número
   de pagos necesarios.
5. **Liquidaciones entre dos participantes concretos** dentro del grupo.
6. **Traslado de saldo entre grupos** (ver `DISENO-TRASLADO-SALDO.md`)
   únicamente cuando **la persona deudora y la acreedora pertenezcan a los dos
   grupos**.

## 3. Cambio de esquema previsto

Una tabla de participaciones por gasto, que es lo que hoy no existe:

```sql
create table public.expense_shares (
    expense_id uuid not null references public.expenses(id) on delete cascade,
    user_id    uuid not null references public.profiles(id),
    -- Exactamente una de las dos, según cómo se haya repartido:
    share      numeric(8,6),   -- fracción del total
    amount     numeric(12,2),  -- cantidad exacta
    primary key (expense_id, user_id),
    constraint ck_share_o_amount check (num_nonnulls(share, amount) = 1)
);
```

Con la invariante de que, por gasto, las fracciones suman 1 o las cantidades
suman el importe. Se comprueba con un trigger `deferrable`, porque la suma solo
es válida cuando están todas las filas.

`payer_share` se conserva para los gastos de dos personas ya existentes; el
motor nuevo lee `expense_shares` si hay filas y cae a `payer_share` si no. Así
la migración no reescribe el histórico.

## 4. Comprobación: ¿el esquema actual lo impide? — **No**

| Necesidad | ¿La bloquea el modelo propuesto? |
|---|---|
| Grupos de N personas | **No.** `group_members` no tiene límite de filas por grupo |
| Que cada gasto tenga varios participantes | **No.** Hace falta añadir `expense_shares`, pero nada del esquema actual lo impide |
| Balance individual por persona | **No.** Se calcula sobre `expenses` + `expense_shares` + `settlements` |
| Liquidación entre dos participantes concretos | **No, ya funciona.** `settlements` tiene `from_user` y `to_user`, y `liquidaciones_crear` exige que ambos sean miembros del grupo |
| Que solo los miembros vean y escriban | **No.** Las políticas usan `es_miembro(group_id)`, que no presupone dos personas |
| Traslado de saldo con deudor y acreedor en ambos grupos | **No.** `liquidaciones_crear` ya lo impone por sí sola |

**Nada del modelo de esta fase hay que deshacerlo para llegar aquí.** Al
contrario: `group_members` es el requisito previo, y las políticas RLS ya están
escritas sin suponer en ningún sitio que un grupo tenga dos personas. El
supuesto de «dos» vive únicamente en la interfaz y en `payer_share`.

## 5. Invitaciones, sin enumerar usuarios

Al crear un grupo, el creador queda como **propietario y único miembro**, y
elige después:

- **Solo para mí** — no hace nada más;
- **Compartir con Pilar** — invitación a un contacto conocido;
- **Invitar a otra persona** — por correo.

Requisito de privacidad: **no debe poder buscarse ni enumerarse la lista de
usuarios registrados.** La política `profiles_leer` ya lo impide —solo se ven
los perfiles con los que se comparte grupo—, así que la invitación **no puede**
implementarse como «buscar usuario y añadir». Hará falta:

- invitar por correo, resolviendo el destinatario **en el servidor** (una RPC
  `SECURITY DEFINER` que no devuelva si ese correo existe o no), o
- un código de invitación de un solo uso que la otra persona canjea.

En los dos casos la invitación debe ser **explícita y aceptada o verificada**,
nunca un alta automática.

## 6. Qué NO hacer mientras tanto

- No calcular saldos en grupos de tres o más «aproximando».
- No repartir contra «la otra persona» elegida arbitrariamente: es exactamente
  el fallo R1 del informe de auditoría.
- No meter a nadie en un grupo automáticamente, ni al registrarse ni al crear
  un grupo nuevo.
