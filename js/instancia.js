// ============================================================
//  Qué instancia se está ejecutando
//
//  El mismo `js/app.js` sirve a todas las instancias. Lo que las distingue
//  es este módulo, que resuelve UNA vez cuál está activa.
//
//  Orden de resolución:
//   1. `window.__INSTANCIA__`, que planta el index.html generado. Es la vía
//      normal y la única que importa en producción.
//   2. La ruta. Respaldo por si un index.html quedara servido sin el script
//      (por ejemplo desde una copia antigua del service worker).
//   3. `POR_DEFECTO`. Es lo que ocurre en Node, donde no hay ni window ni
//      location: las pruebas que importan `config.js` siguen viendo valores
//      reales en vez de undefined.
//
//  `resolverId` es puro y recibe su entorno, para poder probarlo sin navegador.
// ============================================================

import { REGISTRO, POR_DEFECTO, INSTANCIAS } from '../instancias/registro.js';

/**
 * @param {{ marca?: string, ruta?: string }} entorno
 * @returns {string} id de instancia, siempre uno que existe en el registro.
 */
export function resolverId({ marca, ruta } = {}) {
    if (marca && REGISTRO[marca]) return marca;

    if (typeof ruta === 'string') {
        const segmentos = ruta.split('/').filter(Boolean);
        // De más específico a menos: si alguna vez hubiera rutas anidadas,
        // gana la más profunda.
        for (const inst of [...INSTANCIAS].sort((a, b) => b.ruta.length - a.ruta.length)) {
            if (inst.ruta && segmentos.includes(inst.ruta)) return inst.id;
        }
    }

    return POR_DEFECTO;
}

function entornoDelNavegador(global = globalThis) {
    return {
        marca: global.__INSTANCIA__,
        ruta: global.location?.pathname,
    };
}

/** Id de la instancia activa. */
export const ID_INSTANCIA = resolverId(entornoDelNavegador());

/** Descriptor completo de la instancia activa. */
export const INSTANCIA = REGISTRO[ID_INSTANCIA];

/**
 * Aviso en consola si la instancia está a medio configurar. No rompe la app:
 * es preferible que arranque y falle al hablar con Supabase con un mensaje
 * claro, a una pantalla en blanco.
 */
export function instanciaConfigurada(inst = INSTANCIA) {
    return !String(inst.supabaseUrl).includes('PENDIENTE')
        && !String(inst.supabaseAnonKey).includes('PENDIENTE');
}
