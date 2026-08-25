# Cierre de la Fase 2

**25 de agosto de 2026.** Producción migrada, desplegada y verificada.

Este documento es el acta: qué se aplicó, con qué evidencia, y qué queda vivo
después. Los documentos de trabajo —`INFORME-AUDITORIA.md`, `INFORME-FINAL.md`,
`FASE-2-VALIDACION-COPIA.md`— se conservan como estaban; describen el proceso,
no el estado final.

---

## 1. Qué hay desplegado

| | |
|---|---|
| `main` | `00cb707333758fee6197fe880b71ecf13a606dd4` |
| Merge de la Fase 1 (PR #1) | `bcb506f63de8dd4e564ff234e896bd3baaf9eafc` |
| Merge de la Fase 2 (PR #2) | `00cb707333758fee6197fe880b71ecf13a606dd4` |
| SHA revisado de la Fase 1 | `6ee000aca2c2743a8984b9d4965feb85127548b6` |
| SHA revisado de la Fase 2 | `05b7d0df2ccdde8f94a1a6982488342bc0a77b73` |
| `main` antes de todo | `cbc1e1336065f4184aff2e61c0df06ca22e2d25b` |

Los dos merges son **merge commits reales**, sin squash ni rebase. La rama
`estabilizacion/fase-1` se conserva.

**El frontend se sirve por GitHub Pages directamente desde `main`.** No hay
workflow de despliegue ni proveedor externo: fusionar a `main` publica. Conviene
tenerlo presente antes de cualquier merge futuro.

---

## 2. El orden que se siguió, y por qué

Producción tenía el registro de cuentas abierto y trece políticas `using (true)`:
cualquiera que se registrara podía leer los 53 gastos. Esa ventana solo la cierra
`0004`, así que **las migraciones fueron primero** y el frontend después.

1. Respaldo nuevo con `pg_dump` 17, verificado con `pg_restore --list`.
2. Precheck de producción en transacción de solo lectura.
3. Las cinco migraciones, con `supabase/aplicar-migraciones.sh` ejecutado desde
   el checkout de `estabilizacion/fase-1` en `6ee000a`. **Ejecutar el script
   desde la rama revisada no es fusionarla**: no invoca git y solo abre
   conexiones `psql`.
4. Validación SQL inmediata, **antes** de tocar el frontend.
5. Merge de PR #1 → Pages publica el frontend nuevo.
6. Retarget y merge de PR #2 (solo herramientas y documentación).

---

## 3. Resultado de las migraciones

```
0001_baseline_esquema.sql        ok   handle_new_user() ya existía: se conserva
                                      on_auth_user_created ya existía: no se crea otro
lotes/pertenencia.sql            ok   Backfill: 6 membresías insertadas
                                      3 grupos con 2 miembros y 2 propietarios cada uno
0003_restricciones_indices.sql   ok
0004_rls.sql                     ok   13 política(s) retiradas de las tablas de gastos
                                      Políticas de la aplicación de viajes intactas: 12
0005_realtime.sql                ok
```

Validación posterior, sobre producción:

```
 perfiles | grupos | gastos | liquidaciones | cuentas | membresias
        2 |      3 |     53 |             1 |       2 |          6

VALIDACION CORRECTA: datos intactos, pertenencia correcta,
                     RLS cerrada, viajes intacta, Realtime correcto.
99_comprobaciones.sql → Todas las comprobaciones del esquema han pasado
```

Cubre: dos propietarios en cada grupo, RLS activa en las cinco tablas, cero
políticas históricas supervivientes, cero políticas abiertas con `true` en las
tablas de gastos, un único mecanismo de alta, las cinco tablas de gastos en
`supabase_realtime`, ninguna tabla de viajes publicada, la frontera de viajes
idéntica, y cero pagadores o partes de liquidación fuera de su grupo.

**Recorrido autenticado**: confirmado por Dani con las dos cuentas. Los tres
grupos y el histórico cargan, las escrituras y borrados funcionan, Realtime
transmite entre ambas cuentas, y el frontend servido es la v16.

---

## 4. Lo que se aprendió por el camino

Cuatro fallos que ninguna revisión sobre papel había detectado, y que solo
aparecieron al ejecutar contra datos reales:

1. **La fotografía previa no se podía tomar.** `tomar_foto()` es `language sql`
   y PostgreSQL analiza su cuerpo al crear la función: la referencia literal a
   `public.group_members` reventaba el `CREATE FUNCTION` justo cuando la tabla
   aún no existe. Sin foto de «antes» no hay con qué comparar.
2. **El Realtime de las tablas de gastos no se fotografiaba**: solo se capturaba
   dentro de la frontera `viajes:%`.
3. **La copia no traía las publicaciones**: `pg_dump --schema` no las incluye.
   Hay que reconstruir `supabase_realtime` antes de validar, o `0005` la crea de
   cero y la validación no demuestra nada.
4. **La prueba del tercero autenticado no llegaba a ejecutarse**, porque en la
   copia nadie pertenece al rol `authenticated`. Todo lo demás salía verde: un
   verde con la comprobación que más importa sin correr.

El patrón se repite: *un verde puede significar que la comprobación no se
ejecutó*. Conviene exigir que cada comprobación diga lo que ha comprobado, no
solo que no ha fallado.

---

## 5. Lo que queda vivo

### Pendiente de autorización separada

- **Limpieza de copias y respaldos.** Siguen intactos: el respaldo previo al
  despliegue, los volcados anteriores, los directorios de registros y las dos
  copias locales (PostgreSQL 15 y 17). El procedimiento de conservación cifrada
  y borrado está en `FASE-2-VALIDACION-COPIA.md`; **no se ha ejecutado nada**.

### Funciones pendientes, cada una por su cuenta

- **Trasladar saldo entre grupos** — ver §0 de [`PENDIENTES.md`](PENDIENTES.md).
- Grupos de más de dos personas — ver §0.a.
- Mover un gasto entre grupos — ver §0.c.
- Invitaciones a un grupo — ver §7.

### Fronteras declaradas y no validadas

- **`supabase_realtime_messages_publication`** pertenece al esquema `realtime`,
  que estas migraciones no tocan.
- **Las 12 políticas de la aplicación de viajes son `using (true)`**: esa
  aplicación queda abierta a cualquier cuenta autenticada. Está fuera del
  alcance de esta fase y no se ha tocado, pero **merece una decisión aparte**.
- **El CI valida sobre PostgreSQL 15 y producción es 17.** Lo cerró la
  validación sobre una copia real, que sí era 17; el CI sigue en 15.
