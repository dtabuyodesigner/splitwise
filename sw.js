// ============================================================
//  Service worker
//  Guarda la app en el móvil para que abra sin cobertura.
//  Sube el número de VERSION cada vez que edites index.html:
//  es lo que fuerza la actualización en los móviles.
// ============================================================

const VERSION = 'gastos-v5';

const ARCHIVOS = [
    './',
    './index.html',
    './manifest.json',
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

self.addEventListener('fetch', (evento) => {
    const peticion = evento.request;

    if (peticion.method !== 'GET') return;

    const url = new URL(peticion.url);

    // Las llamadas a Supabase van siempre a la red.
    if (url.hostname.endsWith('.supabase.co')) return;

    const mismoOrigen = url.origin === self.location.origin;
    const esExterno = EXTERNOS.includes(url.hostname);

    if (!mismoOrigen && !esExterno) return;

    // Navegación: la red primero, y si no hay, la copia guardada.
    if (peticion.mode === 'navigate') {
        evento.respondWith(
            fetch(peticion)
                .then((respuesta) => {
                    const copia = respuesta.clone();
                    caches.open(VERSION).then((cache) => cache.put('./index.html', copia));
                    return respuesta;
                })
                .catch(() => caches.match('./index.html'))
        );
        return;
    }

    // Recursos: la copia guardada primero, y se refresca por detrás.
    evento.respondWith(
        caches.match(peticion).then((guardado) => {
            const red = fetch(peticion)
                .then((respuesta) => {
                    if (respuesta && respuesta.status === 200) {
                        const copia = respuesta.clone();
                        caches.open(VERSION).then((cache) => cache.put(peticion, copia));
                    }
                    return respuesta;
                })
                .catch(() => guardado);

            return guardado || red;
        })
    );
});
