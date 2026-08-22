# Estado inicial — antes de la fase 1 de estabilización

Documento congelado. Describe el repositorio **tal y como estaba** al abrir la rama de trabajo.
No se modifica en commits posteriores.

## Referencias git

| Dato | Valor |
|---|---|
| Repositorio | https://github.com/dtabuyodesigner/splitwise |
| Rama base | `main` |
| SHA base (HEAD de `main`) | `cbc1e1336065f4184aff2e61c0df06ca22e2d25b` |
| Mensaje del commit base | `v15: estadísticas por categoría, búsqueda y filtros, edición de liquidaciones, modo oscuro y robustez offline` |
| Rama de trabajo creada | `estabilizacion/fase-1` |
| Árbol de trabajo al crear la rama | limpio (`git status` sin cambios) |

## Inventario de archivos

| Archivo | Líneas | SHA-256 |
|---|---|---|
| `index.html` | 4076 | `ee192e68ed5b24895263be1ed75ce419e9b42e88600c78867f810a0454cddfb2` |
| `sw.js` | 86 | `be57cb67d7511974a106fd358d15e6c32ec4585c96184aeb4c626a3cf0f5d40d` |
| `manifest.json` | 38 | `23789f6e085df2060098318858cdefc2b783df5324b3b813c735715bda0edaf7` |
| `README.md` | 117 | `2d255f4f6d2e878d2f49ee8cb8a72567b29b8588a4328f210f8cd9b9eca6be80` |

Total: **4 archivos**, ~138 KB en `index.html`.

No existía en el repositorio, antes de esta fase:

- ninguna migración SQL ni definición de políticas RLS,
- ninguna prueba automatizada,
- ninguna configuración de CI,
- ningún `package.json`,
- ningún icono real (solo data URI en `manifest.json` e `index.html`),
- ningún documento de seguridad.

## Composición de `index.html` (estado inicial)

| Tramo | Líneas | Contenido |
|---|---|---|
| `<head>` | 1–1043 | metadatos, iconos data-URI, fuentes de Google Fonts, **1020 líneas de CSS en línea** |
| `<body>` markup | 1045–1370 | pantalla de acceso, pantalla de app, 5 hojas modales |
| `<script type="module">` | 1371–4074 | **2703 líneas**: toda la lógica de la aplicación |

Estructura interna del script (orden original):

1. Configuración Supabase y constantes (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `CATEGORIES`, `CATEGORY_META`)
2. Estado global (`estado`) y claves de `localStorage`
3. Utilidades (`aNumero`, `formatoDinero`, `hoyISO`, `escapar`, `recado`)
4. Copia local: `guardarCache` / `leerCache` / `guardarCola` / `leerCola`
5. Sesión: `acceder`, `accederConGoogle`, `traducirError`, `salir`
6. Datos: `repartirPerfiles`, `cargarTodo`, `reponerPendientes`
7. Cola offline: `encolar`, `vaciarCola`, `refrescar`
8. Balance: `calcularSaldo`
9. Pintado: `pintar` y ~12 funciones `pintarX`
10. Estadísticas, compartir, exportar CSV/JSON
11. Importador CSV: `trocearCSV`, `analizarCSV`, `confirmarImportacion`, `deshacerImportacion`
12. Grupos: crear / renombrar / vaciar / borrar
13. Dictado: `PISTAS_CATEGORIA`, `interpretarDictado`, `prepararMicro`
14. Hoja de gasto: `guardarGasto`, `borrarGasto`
15. Hoja de liquidación: `guardarLiquidacion`, `borrarLiquidacion`
16. Realtime: `escucharCambios`
17. Eventos y arranque: `conectarEventos`, `entrarEnLaApp`, `iniciar`

## Contrato de datos observado (deducido del código y del README original)

Tablas usadas por el frontend: `profiles`, `groups`, `expenses`, `settlements`.
El frontend hace `select('*')` sin filtro sobre las cuatro.

Columnas referenciadas explícitamente por el código:

- `profiles`: `id`, `display_name`, `color`, `created_at`
- `groups`: `id`, `name`, `created_at`
- `expenses`: `id`, `group_id`, `paid_by`, `amount`, `description`, `category`, `payer_share`, `spent_on`, `client_id`, `created_at`
- `settlements`: `id`, `group_id`, `from_user`, `to_user`, `amount`, `note`, `settled_on`, `client_id`, `created_at`

`upsert(..., { onConflict: 'client_id' })` se usa en `expenses` y `settlements`, lo que implica
que **debe existir** un índice único sobre `client_id` en ambas tablas. No está verificado.

## Límites codificados en el estado inicial

- `expenses`: `.limit(2500)`
- `settlements`: `.limit(500)`
- `TOPE_FIEL = 300` (solo visual, no afecta al cálculo)
- Importación CSV en lotes de 100 filas

## Claves de `localStorage` en el estado inicial

`gastos.cache`, `gastos.cola`, `gastos.grupo`, `gastos.correo`, `gastos.visita`.
Ninguna está asociada al usuario que ha iniciado sesión.

## Qué NO se ha podido inspeccionar

- El proyecto Supabase real (`cmkzcvfjgrgxwqjimtxa.supabase.co`): esquema efectivo,
  políticas RLS activas, índices, claves foráneas, triggers, número de usuarios y de grupos.
  El servidor MCP de Supabase de esta sesión requiere autenticación interactiva y la sesión
  no lo permite. **No se ha hecho ninguna consulta contra producción.**
