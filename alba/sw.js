// ============================================================
//  Service worker · instancia "alba"
//
//  GENERADO por tools/instancias.mjs a partir de
//  tools/plantillas/sw.js + instancias/registro.js
//  NO EDITAR A MANO: `npm run instancias` lo sobrescribe y CI comprueba
//  que no haya diferencias.
//
//  Guarda la app en el móvil para que abra sin cobertura.
//
//  VERSION tiene que coincidir con VERSION_APP en js/config.js y con
//  "version" en package.json. `npm run verificar` lo comprueba y CI lo
//  ejecuta en cada push: si no coinciden, el build falla.
//
//  Estrategia:
//   · Recursos propios (HTML, CSS, JS, manifest, iconos) → RED PRIMERO,
//     con la copia guardada como respaldo. Así una versión nueva del
//     index.html nunca se empareja con un js/app.js viejo. Sin conexión se
//     sirve la copia completa de la última versión que sí se cargó entera.
//   · Recursos externos (fuentes, CDN de Supabase) → COPIA PRIMERO y se
//     refresca por detrás: son inmutables y conviene que estén al vuelo.
//   · Supabase → siempre a la red, nunca se guarda.
//
//  AISLAMIENTO ENTRE INSTANCIAS
//  `caches` es del ORIGEN, no de la ruta: todas las instancias comparten el
//  mismo almacén de cachés. Por eso:
//   · El nombre de la caché lleva el prefijo de la instancia.
//   · `activate` solo borra cachés que encajen EXACTAMENTE con el patrón de
//     esta instancia. La versión ingenua (`borra todo lo que no sea la mía`)
//     dejaba a la otra instancia sin app al primer despliegue.
//   · `fetch` no atiende rutas de otras instancias, ni siquiera antes de que
//     estas hayan registrado su propio service worker.
// ============================================================

const PREFIJO = 'gastos-alba-';
const VERSION = PREFIJO + 'v18';

/** Solo cachés de ESTA instancia: `<prefijo>v<numero>`, nada más. */
const MIAS = new RegExp('^' + PREFIJO.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&') + 'v\\d+$');

/** Primer segmento de ruta de las demás instancias, relativo a este ámbito. */
const RUTAS_AJENAS = [];

const ARCHIVOS = [
    "./",
    "./index.html",
    "./manifest.json",
    "../styles.css",
    "../js/almacen.js",
    "../js/app.js",
    "../js/balances.js",
    "../js/config.js",
    "../js/csv.js",
    "../js/dinero.js",
    "../js/errores.js",
    "../js/fechas.js",
    "../js/gastos.js",
    "../js/html.js",
    "../js/instancia.js",
    "../js/miembros.js",
    "../js/mutaciones.js",
    "../js/offline-queue.js",
    "../js/supabase-data.js",
    "../js/traslados.js",
    "../js/voice.js",
    "../instancias/registro.js",
    "../icons/apple-touch-180.png",
    "../icons/favicon-32.png",
    "../icons/icon-192.png",
    "../icons/icon-512.png",
    "../icons/maskable-192.png",
    "../icons/maskable-512.png"
];

// Se guardan al vuelo la primera vez que se piden.
const EXTERNOS = [
    'cdn.jsdelivr.net',
    'fonts.googleapis.com',
    'fonts.gstatic.com',
];

self.addEventListener('install', (evento) => {
    evento.waitUntil(
        caches.open(VERSION)
            // addAll es todo o nada: si falta un archivo, no se instala una
            // versión a medias. Mejor quedarse con la anterior, que funciona.
            .then((cache) => cache.addAll(ARCHIVOS))
            .then(() => self.skipWaiting())
    );
});

self.addEventListener('activate', (evento) => {
    evento.waitUntil(
        caches.keys()
            .then((claves) => Promise.all(
                claves
                    .filter((c) => MIAS.test(c) && c !== VERSION)
                    .map((c) => caches.delete(c))
            ))
            .then(() => self.clients.claim())
    );
});

/** ¿Esta URL pertenece a otra instancia? */
function esDeOtraInstancia(url) {
    if (!RUTAS_AJENAS.length) return false;
    const ambito = new URL('./', self.location).pathname;
    if (!url.pathname.startsWith(ambito)) return false;
    const primero = url.pathname.slice(ambito.length).split('/')[0];
    return RUTAS_AJENAS.includes(primero);
}

/** Red primero; si falla, lo guardado. Mantiene coherente toda la versión. */
async function redPrimero(peticion, respaldo) {
    const cache = await caches.open(VERSION);
    try {
        const respuesta = await fetch(peticion);
        if (respuesta && respuesta.status === 200 && respuesta.type !== 'opaque') {
            cache.put(respaldo || peticion, respuesta.clone());
        }
        return respuesta;
    } catch (e) {
        const guardado = await cache.match(respaldo || peticion);
        if (guardado) return guardado;
        throw e;
    }
}

/** Copia primero y refresco por detrás. Para recursos externos inmutables. */
async function copiaPrimero(peticion) {
    const cache = await caches.open(VERSION);
    const guardado = await cache.match(peticion);

    const red = fetch(peticion)
        .then((respuesta) => {
            if (respuesta && respuesta.status === 200) {
                cache.put(peticion, respuesta.clone());
            }
            return respuesta;
        })
        .catch(() => guardado);

    return guardado || red;
}

self.addEventListener('fetch', (evento) => {
    const peticion = evento.request;
    if (peticion.method !== 'GET') return;

    const url = new URL(peticion.url);

    // Las llamadas a Supabase van siempre a la red y nunca se guardan.
    if (url.hostname.endsWith('.supabase.co')) return;

    const mismoOrigen = url.origin === self.location.origin;

    // Nunca responder por otra instancia. Sin esto, la primera visita a
    // /alba/ desde un móvil que ya tenía la raíz instalada recibía el
    // index.html de la raíz como respaldo de navegación.
    if (mismoOrigen && esDeOtraInstancia(url)) return;

    const esExterno = EXTERNOS.includes(url.hostname);
    if (!mismoOrigen && !esExterno) return;

    if (peticion.mode === 'navigate') {
        evento.respondWith(redPrimero(peticion, './index.html'));
        return;
    }

    evento.respondWith(mismoOrigen ? redPrimero(peticion) : copiaPrimero(peticion));
});
