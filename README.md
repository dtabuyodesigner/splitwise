# Gastos Compartidos (Splitwise PWA)

Una aplicación web progresiva (PWA) rápida, elegante y orientada a la privacidad para gestionar gastos compartidos en pareja, viajes o convivencia. Diseñada con un enfoque **Offline-First**, sincronización en tiempo real vía **Supabase**, reconocimiento de voz natural y soporte completo para modo oscuro.

---

## 🌟 Características Principales

1. **Balance en Tiempo Real y Balanza Visual**:
   - Cálculo automático e instantáneo de saldos netos entre dos personas.
   - Indicador visual del fiel de la balanza que muestra la inclinación del balance en función del importe adeudado.
   - Totales globales: Total gastado en el grupo, cuánto ha adelantado cada persona y estado de cuenta (*en paz*, *debes*, *te deben*).

2. **Dictado por Voz Natural e Inteligente**:
   - Parser de lenguaje natural (`interpretarDictado`) que extrae automáticamente:
     - **Importe** (números hablados, céntimos, euros).
     - **Concepto y Categoría** (reconocimiento de supermercados, restaurantes, hoteles, transporte, gasolineras, farmacias, peajes, etc.).
     - **Quién pagó** ("pagué yo", "pagó Dani", "invitó Pilar").
     - **Reparto** ("a medias", "solo para mí", "solo para Pilar", porcentaje personalizado).
   - Soporte para Web Speech API integrado y compatibilidad con el micrófono del teclado nativo en móviles.

3. **Cálculos y Operaciones en el Campo de Importe**:
   - Permite introducir sumas y operaciones matemáticas directamente (por ejemplo `24,50 + 12 + 6,30`) sin necesidad de recurrir a la calculadora externa.

4. **Gestión Completa de Liquidaciones (Saldar Cuentas)**:
   - Registro de pagos con cálculo automático del importe adeudado.
   - Visualización diferenciada de liquidaciones en la lista de movimientos.
   - **Edición y eliminación** de liquidaciones para corregir errores fácilmente.

5. **Búsqueda y Filtros en Tiempo Real**:
   - Barra de búsqueda instantánea por concepto, categoría o persona pagadora.
   - Filtros rápidos mediante chips (*Todos*, *Míos*, *De mi pareja*).
   - Contador dinámico de resultados y suma total filtrada.

6. **Estadísticas y Desglose por Categoría**:
   - Modal de estadísticas con porcentaje de gasto por categoría (Súper, Comer fuera, Alojamiento, Transporte, Ocio, etc.).
   - Comparativa de aportaciones individuales con barras de progreso.
   - Métricas de gasto medio y total de apuntes.

7. **Arquitectura Offline-First**:
   - Almacenamiento local mediante `localStorage` y `Service Worker` (`sw.js`).
   - Cola de sincronización bidireccional (`estado.cola`) para inserciones, modificaciones y eliminaciones realizadas sin cobertura.
   - Sincronización automática en segundo plano en cuanto se recupera la conexión a internet.

8. **Exportación e Importación de Datos**:
   - **Exportar CSV**: Formato compatible con Microsoft Excel (BOM UTF-8, delimitador punto y coma).
   - **Copia de Seguridad JSON**: Backup completo de perfiles, grupos, gastos y liquidaciones.
   - **Compartir Balance**: Envío del resumen de cuentas formateado mediante Web Share API, WhatsApp o portapapeles.
   - **Importador CSV Inteligente**: Detección automática de cabeceras, separadores, fechas e imputación de gastos con opción de deshacer.

9. **Diseño y Estética Premium (Monte de Anaga)**:
   - Paleta cromática natural: *Niebla*, *Basalto*, *Laurel* y *Buganvilla*.
   - Tipografía moderna (*Bricolage Grotesque* e *Inter Tight* con cifras tabulares).
   - Soporte completo para **Modo Oscuro** (automático y adaptable).
   - Iconos por categoría para identificación rápida de cada gasto.

---

## 🛠️ Pila Tecnológica

- **Frontend**: HTML5 semántico, Vanilla CSS3 (Custom Properties, Flexbox, Grid), JavaScript moderno (ES Modules).
- **Backend y Base de Datos**: [Supabase](https://supabase.com) (PostgreSQL, Supabase Auth, Supabase Realtime).
- **PWA & Cache**: Web App Manifest (`manifest.json`), Service Worker (`sw.js`, versión `v15`).
- **APIs Web**: Web Speech API, Web Share API, Clipboard API, Fetch API, LocalStorage.

---

## 🗄️ Modelo de Datos (Supabase)

### Tabla `profiles`
- `id` (UUID, PK, coincide con `auth.users.id`)
- `display_name` (Text, nombre visible en la interfaz)
- `color` (Text, 'laurel' o 'buganvilla')
- `created_at` (Timestamp with time zone)

### Tabla `groups`
- `id` (UUID, PK)
- `name` (Text, nombre del grupo o viaje)
- `created_at` (Timestamp with time zone)

### Tabla `expenses`
- `id` (UUID, PK)
- `group_id` (UUID, FK -> groups.id)
- `paid_by` (UUID, FK -> profiles.id)
- `amount` (Numeric(10,2), importe del gasto)
- `description` (Text, concepto o detalle)
- `category` (Text, categoría del gasto)
- `payer_share` (Numeric(4,2), cuota que asume quien pagó: 0.5 = 50%, 1.0 = 100%, 0.0 = 0%)
- `spent_on` (Date, fecha del gasto 'YYYY-MM-DD')
- `client_id` (Text, identificador único de cliente para sincronización offline)
- `created_at` (Timestamp with time zone)

### Tabla `settlements`
- `id` (UUID, PK)
- `group_id` (UUID, FK -> groups.id)
- `from_user` (UUID, FK -> profiles.id, pagador)
- `to_user` (UUID, FK -> profiles.id, perceptor)
- `amount` (Numeric(10,2), importe liquidado)
- `note` (Text, concepto o nota)
- `settled_on` (Date, fecha del pago)
- `client_id` (Text, identificador único de cliente)
- `created_at` (Timestamp with time zone)

---

## 🚀 Ejecución en Local

Puedes probar la aplicación en local con cualquier servidor web estático:

```bash
# Con Python 3:
python3 -m http.server 8080 --directory ./splitwise

# O con npx serve:
npx serve ./splitwise
```

Abre `http://localhost:8080` en tu navegador móvil o de escritorio.