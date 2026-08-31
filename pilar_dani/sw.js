// ============================================================
//  Service worker
//
//  Guarda la app en el móvil para que abra sin cobertura.
//
//  VERSION tiene que coincidir con VERSION_APP en js/config.js y con
//  "version" en package.json. `npm run verificar` lo comprueba y CI lo
//  ejecuta en cada push: si no coinciden, el build falla.
//
//  Estrategia (corrige el riesgo R14):
//   · Recursos propios (HTML, CSS, JS, manifest, iconos) → RED PRIMERO,
//     con la copia guardada como respaldo. Así una versión nueva del
//     index.html nunca se empareja con un js/app.js viejo. Sin conexión se
//     sirve la copia completa de la última versión que sí se cargó entera.
//   · Recursos externos (fuentes, CDN de Supabase) → COPIA PRIMERO y se
//     refresca por detrás: son inmutables y conviene que estén al vuelo.
//   · Supabase → siempre a la red, nunca se guarda.
// ============================================================

const VERSION = 'gastos-v17';

const ARCHIVOS = [
    './',
    './index.html',
    '../manifest.json',
    '../styles.css',
    '../js/app.js',
    '../js/config.js',
    '../js/dinero.js',
    '../js/fechas.js',
    '../js/html.js',
    '../js/errores.js',
    '../js/balances.js',
    '../js/miembros.js',
    '../js/almacen.js',
    '../js/offline-queue.js',
    '../js/supabase-data.js',
    '../js/mutaciones.js',
    '../js/gastos.js',
    '../js/csv.js',
    '../js/voice.js',
    '../js/traslados.js',
    '../js/invitaciones.js',
    '../icons/icon-192.png',
    '../icons/icon-512.png',
    '../icons/maskable-192.png',
    '../icons/maskable-512.png',
    '../icons/apple-touch-180.png',
    '../icons/favicon-32.png',
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
                claves.filter((c) => c !== VERSION).map((c) => caches.delete(c))
            ))
            .then(() => self.clients.claim())
    );
});

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
    const esExterno = EXTERNOS.includes(url.hostname);
    if (!mismoOrigen && !esExterno) return;

    if (peticion.mode === 'navigate') {
        evento.respondWith(redPrimero(peticion, './index.html'));
        return;
    }

    evento.respondWith(mismoOrigen ? redPrimero(peticion) : copiaPrimero(peticion));
});
