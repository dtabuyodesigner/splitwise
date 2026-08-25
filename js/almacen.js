// ============================================================
//  Almacenamiento local aislado por usuario
//
//  Corrige el riesgo R3: en el monolito original las claves
//  `gastos.cache`, `gastos.cola`, `gastos.grupo` y `gastos.visita` eran
//  globales al navegador, así que la cola pendiente de una cuenta podía
//  sincronizarse con la sesión de otra.
//
//  Esquema nuevo:  gastos.v2.<user_id>.<nombre>
//  `gastos.correo` sigue siendo global a propósito: se usa ANTES de
//  saber quién entra, solo recuerda el último correo escrito.
//
//  El almacén se inyecta (por defecto `localStorage`) para poder probarlo.
// ============================================================

export const PREFIJO = 'gastos.v2';
export const CLAVE_CORREO = 'gastos.correo';

/** Claves del esquema antiguo, sin dueño conocido. */
export const CLAVES_HEREDADAS = [
    'gastos.cache', 'gastos.cola', 'gastos.grupo', 'gastos.visita',
];

const NOMBRES = ['cache', 'cola', 'grupo', 'visita'];

/** Almacén de respaldo en memoria: navegadores en modo privado, Node, etc. */
export function almacenEnMemoria(inicial = {}) {
    const datos = new Map(Object.entries(inicial));
    return {
        getItem: (k) => (datos.has(k) ? datos.get(k) : null),
        setItem: (k, v) => { datos.set(k, String(v)); },
        removeItem: (k) => { datos.delete(k); },
        key: (i) => [...datos.keys()][i] ?? null,
        get length() { return datos.size; },
    };
}

function almacenPorDefecto() {
    try {
        if (typeof localStorage !== 'undefined') {
            localStorage.setItem('gastos.prueba', '1');
            localStorage.removeItem('gastos.prueba');
            return localStorage;
        }
    } catch { /* modo privado o cookies bloqueadas */ }
    return almacenEnMemoria();
}

export function crearAlmacen(userId, almacen = almacenPorDefecto()) {
    if (!userId) throw new Error('crearAlmacen necesita un user_id');
    const clave = (nombre) => PREFIJO + '.' + userId + '.' + nombre;

    return {
        userId,
        clave,

        leer(nombre, porDefecto = null) {
            try {
                const bruto = almacen.getItem(clave(nombre));
                return bruto == null ? porDefecto : JSON.parse(bruto);
            } catch {
                return porDefecto;
            }
        },

        escribir(nombre, valor) {
            try {
                almacen.setItem(clave(nombre), JSON.stringify(valor));
                return true;
            } catch {
                // Cuota agotada o almacenamiento bloqueado: no es motivo para
                // romper la app, pero tampoco se finge que se ha guardado.
                return false;
            }
        },

        borrar(nombre) {
            try { almacen.removeItem(clave(nombre)); } catch { /* nada que hacer */ }
        },

        /** Borra todo lo de ESTE usuario. No toca lo de nadie más. */
        limpiar() {
            for (const n of NOMBRES) this.borrar(n);
        },
    };
}

/** Todas las claves presentes, para inspección y limpieza. */
function todasLasClaves(almacen) {
    const claves = [];
    try {
        for (let i = 0; i < almacen.length; i++) {
            const k = almacen.key(i);
            if (k != null) claves.push(k);
        }
    } catch { /* almacén sin enumeración */ }
    return claves;
}

/** Borra los datos locales de cualquier usuario distinto del indicado. */
export function purgarOtrosUsuarios(userId, almacen = almacenPorDefecto()) {
    let borradas = 0;
    for (const k of todasLasClaves(almacen)) {
        if (!k.startsWith(PREFIJO + '.')) continue;
        const dueño = k.slice(PREFIJO.length + 1).split('.')[0];
        if (dueño !== userId) {
            try { almacen.removeItem(k); borradas++; } catch { /* nada que hacer */ }
        }
    }
    return borradas;
}

/**
 * Migración única del esquema antiguo al nuevo.
 *
 * `cache`, `grupo` y `visita` son datos derivados: se descartan, se
 * reconstruyen solos en la primera carga.
 *
 * `gastos.cola` sí contiene trabajo del usuario que se perdería. Se adopta
 * bajo el usuario que tiene la sesión abierta, que es exactamente lo que
 * habría hecho la versión anterior con esa misma cola. A partir de aquí el
 * aislamiento es efectivo. Se marca `adoptada:true` para poder avisarlo.
 *
 * @returns {{adoptadas: number, descartadas: string[]}}
 */
export function migrarDesdeEsquemaAntiguo(userId, almacen = almacenPorDefecto()) {
    const resultado = { adoptadas: 0, descartadas: [] };
    if (!userId) return resultado;

    let colaAntigua = [];
    try {
        const bruto = almacen.getItem('gastos.cola');
        if (bruto) colaAntigua = JSON.parse(bruto) || [];
    } catch { colaAntigua = []; }

    if (Array.isArray(colaAntigua) && colaAntigua.length) {
        const propia = crearAlmacen(userId, almacen);
        const actual = propia.leer('cola', []) || [];
        const adoptadas = colaAntigua.map((t) => ({
            ...t,
            owner_user_id: userId,
            adoptada: true,
            intentos: 0,
        }));
        propia.escribir('cola', [...actual, ...adoptadas]);
        resultado.adoptadas = adoptadas.length;
    }

    for (const k of CLAVES_HEREDADAS) {
        try {
            if (almacen.getItem(k) != null) {
                almacen.removeItem(k);
                resultado.descartadas.push(k);
            }
        } catch { /* nada que hacer */ }
    }

    return resultado;
}
