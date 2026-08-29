# Multi-instancia

Cómo funcionan los despliegues independientes de esta aplicación y cómo se
crea uno nuevo.

---

## 1. Qué es una instancia

Una **instancia** es un despliegue independiente de la *misma* aplicación.
Dos instancias no comparten ni un dato: ni gastos, ni grupos, ni usuarios, ni
sesiones, ni copias locales.

Hoy existen dos:

| Instancia | URL | Para quién | Proyecto de Supabase |
|---|---|---|---|
| `dani` | `/` | Dani y Pilar | `cmkzcvfjgrgxwqjimtxa` |
| `alba` | `/alba/` | Alba | `wspcrnqdoucohattians` |

Lo que **cambia** entre instancias son cinco cosas, y ninguna es código de
aplicación:

1. A qué proyecto de Supabase habla.
2. Bajo qué prefijo guarda en `localStorage`.
3. Bajo qué nombre guarda su caché de service worker.
4. Bajo qué clave guarda la sesión.
5. Los textos: nombre, nombre corto, lema.

Lo que **se comparte** es todo lo demás: `styles.css`, los 18 módulos de
`js/` y los iconos de `icons/`. No hay una copia de la aplicación por
instancia. Corregir un fallo en `js/balances.js` lo corrige en todas a la vez.

---

## 2. Estructura

```
instancias/
  registro.js            ÚNICA fuente de verdad de qué instancias existen

js/
  instancia.js           resuelve cuál está activa en tiempo de ejecución
  config.js              reexporta los valores de la instancia activa
  app.js  balances.js  …  COMPARTIDOS por todas

styles.css               COMPARTIDO
icons/                   COMPARTIDO

tools/
  plantillas/
    index.html           ┐
    manifest.json        ├ de aquí salen los archivos de cada instancia
    sw.js                ┘
  instancias.mjs         el generador
  registrar-instancia.mjs  añade una entrada al registro

index.html               GENERADO · instancia dani
manifest.json            GENERADO · instancia dani
sw.js                    GENERADO · instancia dani

alba/index.html          GENERADO · instancia alba
alba/manifest.json       GENERADO · instancia alba
alba/sw.js               GENERADO · instancia alba
```

> **Los seis archivos marcados como GENERADOS no se editan a mano.**
> `npm run instancias` los reescribe y CI comprueba que no haya diferencias.
> Para cambiar algo en ellos, se cambia la plantilla o el registro.

### Cómo sabe la app qué instancia es

El `index.html` generado lleva una línea:

```html
<script>window.__INSTANCIA__ = "alba";</script>
```

`js/instancia.js` la lee y busca la entrada en el registro. Si no la
encuentra, deduce la instancia por la ruta, y si tampoco, usa `POR_DEFECTO`.
Ese último caso es el que hace que las pruebas puedan importar `config.js`
desde Node, donde no hay `window` ni `location`.

### Por qué subcarpetas y no subdominios

GitHub Pages sirve un único dominio por repositorio. Una subcarpeta es lo
único que se puede hacer sin comprar dominios ni montar servidor. Tiene una
consecuencia importante, que es de donde salen casi todas las decisiones de
la sección siguiente:

> `localStorage` y `caches` pertenecen al **origen**, no a la ruta.
> `/` y `/alba/` los comparten.

---

## 3. El aislamiento, y por qué no era gratis

Al añadir la segunda instancia aparecieron tres formas de que una borrara
datos de la otra. Las tres están corregidas y las tres tienen prueba de
regresión en `tests/instancias.test.js`.

### 3.1 La cola pendiente

`purgarOtrosUsuarios()` borra, al entrar, todo lo guardado que no sea del
usuario actual. Con dos instancias en el mismo origen, eso incluía la cola de
cambios sin sincronizar de la otra.

La solución es que **ningún prefijo pueda ser prefijo de otro**:

```
dani →  gastos.v2.<user_id>.<nombre>
alba →  gastos.alba.v2.<user_id>.<nombre>
```

El id va **antes** de la versión a propósito. Si fuera `gastos.v2.alba.…`,
el prefijo de `dani` (`gastos.v2.`) contendría al de `alba` y volveríamos al
mismo problema. `tools/instancias.mjs` valida esta invariante y el generador
se niega a funcionar si alguien la rompe.

Como segundo cinturón, `purgarOtrosUsuarios` exige además que lo que queda
detrás del prefijo tenga la forma exacta `<user_id>.<nombre>` con un nombre
conocido. Una clave ajena no la tiene y sobrevive aunque el prefijo se
solapara.

### 3.2 La caché del service worker

El `activate` original borraba toda caché que no fuera la suya. Con dos
instancias, desplegar dejaba a la otra sin aplicación offline hasta la
siguiente vez que tuviera cobertura.

Ahora cada service worker solo borra cachés que encajen **exactamente** con
su patrón `^<prefijo>v\d+$`:

```
dani →  gastos-v18        patrón  ^gastos-v\d+$
alba →  gastos-alba-v18   patrón  ^gastos-alba-v\d+$
```

`gastos-alba-v18` no encaja con `^gastos-v\d+$`, así que la raíz no puede
tocarla. El generador también valida esto.

### 3.3 Responder por la instancia vecina

El service worker de la raíz tiene ámbito `/`, que incluye `/alba/`. Antes de
que Alba registrara el suyo, una navegación a `/alba/` recibía el
`index.html` de la raíz como respaldo. Cada service worker lleva ahora la
lista de rutas ajenas y no las atiende.

### 3.4 La sesión

`createClient` recibe un `storageKey` explícito (`sb-<id>-auth`). Con
proyectos distintos la clave por defecto ya sería distinta, pero dejarlo al
azar de la implementación de `supabase-js` no compensa.

### 3.5 Compatibilidad hacia atrás

La instancia `dani` conserva a propósito los prefijos antiguos
(`gastos.v2`, `gastos.correo`, `gastos-`), declarados de forma explícita en
el registro. Cambiarlos habría borrado la cola pendiente de Dani y Pilar y
duplicado el icono en sus pantallas de inicio. Es la única instancia con
estos valores fijados a mano; las nuevas los derivan de su id.

Del mismo modo, `migrarDesdeEsquemaAntiguo()` solo adopta las claves
heredadas (`gastos.cola` y compañía) si la instancia es la heredada. Una
instancia nueva ni las adopta ni las borra: no son suyas.

---

## 4. Crear una instancia nueva

Son dos partes. La primera hay que hacerla a mano porque requiere tu cuenta;
la segunda está automatizada.

### 4.1 El proyecto de Supabase (a mano, una vez)

Cada instancia necesita su **propio proyecto**. Esto es lo que hace que el
aislamiento sea real y no una convención: son bases de datos distintas, con
usuarios distintos, en servidores distintos.

1. En [supabase.com](https://supabase.com) → **New project**. Elige región
   cercana (`eu-west` para Canarias) y guarda la contraseña de la base.
2. **SQL Editor** → aplica las migraciones de `supabase/migrations/` en este
   orden, que es el mismo que usa CI y `supabase/aplicar-migraciones.sh`:

   ```
   0001_baseline_esquema
   lotes/pertenencia
   0003_restricciones_indices
   0004_rls
   0005_realtime
   0006_rls_viajes
   0007_traslado_de_saldo
   0008_privilegios_de_funciones
   0009_privilegios_por_defecto
   ```

   Son idempotentes: si una se queda a medias, se puede reejecutar.
3. **Authentication → Providers**: deja activo *Email*. Si quieres que solo
   entren personas invitadas, desactiva *Enable sign ups* y da de alta las
   cuentas tú desde *Users → Add user*.
4. **Project settings → API**: copia la **Project URL** y la clave
   **`anon` `public`**.

> **Nunca copies la clave `service_role`.** Salta RLS por completo. El
> workflow de creación la rechaza descodificando el JWT, pero la primera
> defensa eres tú.

### 4.2 Registrar y generar

**Desde el móvil, sin ordenador:**

GitHub → pestaña **Actions** → **Nueva instancia** → **Run workflow**.
Rellena id, nombre, nombre corto, URL y clave anon. El workflow registra la
instancia, genera sus archivos, ejecuta las pruebas y abre un pull request.
Si algo falla no hace commit. Al fusionar, Pages publica `/<id>/` en un par
de minutos.

**Desde la terminal:**

```bash
ID=marta NOMBRE='Gastos de Marta' NOMBRE_CORTO='Gastos Marta' \
URL=https://xxxx.supabase.co CLAVE=eyJ... \
node tools/registrar-instancia.mjs

npm run instancias
npm test && npm run verificar
```

O editando `instancias/registro.js` a mano y ejecutando `npm run instancias`.
Las tres vías acaban en el mismo sitio.

### 4.3 Primer acceso

La instancia nueva no tiene ni usuarios ni grupos. Quien entre se registra
con su correo, crea un grupo desde la hoja **Grupos** y a partir de ahí
funciona igual que la original.

---

## 5. Publicar una versión

El número de versión vive en tres sitios que tienen que coincidir, y
`npm run verificar` lo comprueba:

- `js/config.js` → `VERSION_APP`
- `package.json` → `version` (el número mayor)
- el `sw.js` de **cada** instancia → generado, así que se actualiza solo

Para subir de versión:

```bash
# js/config.js: VERSION_APP = 'v19'
# package.json: "version": "19.0.0"
npm run instancias
npm test && npm run verificar
```

Sin cambiar la versión, los móviles se quedan con la copia guardada.

---

## 6. Lo que comprueba CI

En el job `pruebas`, además de lo que ya había:

| Paso | Qué impide |
|---|---|
| Sintaxis, descubriendo los `sw.js` | Que un `sw.js` nuevo se quede sin comprobar |
| JSON válido, todos los `manifest.json` | Un manifest roto en una instancia que no miras |
| `tools/verificar.mjs` | Versiones descuadradas, módulos sin cachear, iconos mal declarados, **en cada instancia** |
| `tools/instancias.mjs --check` + `git diff` | Que alguien edite a mano un archivo generado y el cambio se pierda al regenerar |
| `tests/instancias.test.js` | Las tres regresiones de la sección 3 |

---

## 7. Preguntas que van a surgir

**¿Puedo mover la instancia raíz a `/dani/`?**
Se puede, pero rompería las PWA ya instaladas en los móviles de Dani y Pilar:
tendrían que borrar el icono y volver a añadirlo, y perderían la cola
pendiente. Por eso la raíz sigue siendo una instancia y no un índice.

**¿Cuántas instancias caben?**
En el repositorio, las que quieras. El límite está en Supabase: el plan
gratuito permite dos proyectos activos por organización. Para la tercera hay
que pagar, usar otra organización, o replantear el modelo.

**¿Y si quisiera compartir la base y separar por columna `instancia_id`?**
Sería más barato en proyectos de Supabase y mucho peor en aislamiento: todo
el peso recaería en que las políticas RLS estén perfectas, y un fallo
expondría los datos de una persona a otra. Con proyectos separados, un fallo
de RLS solo afecta a quien ya está dentro de esa instancia. Se eligió lo
segundo a propósito.

**¿Se puede borrar una instancia?**
Quita su entrada del registro, ejecuta `npm run instancias` y borra su
carpeta. Los datos siguen en su proyecto de Supabase hasta que lo elimines
allí. Quien la tuviera instalada seguirá viendo el icono, pero la app dejará
de cargar.
