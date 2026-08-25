// ============================================================
//  Escrituras: guardar, editar y borrar
//
//  Corrige:
//   R2  el error se clasifica; solo lo recuperable va a la cola
//   R4  el estado local se restaura si el servidor rechaza el cambio
//   R5  update/delete comprueban las filas realmente afectadas
//   R6  ediciones y borrados de apuntes aún pendientes se fusionan en la cola
//
//  Todas las funciones devuelven un resultado explícito:
//    { estado: 'servidor' | 'pendiente' | 'duplicado' | 'sesion' | 'error',
//      clase, mensaje, fila }
//
//  Módulo sin DOM: recibe el cliente, la cola y las listas locales.
// ============================================================
import { CLASE, clasificarError } from './errores.js';
import { TIPO } from './offline-queue.js';

function resultado(estado, extra = {}) {
    return { estado, clase: null, mensaje: null, fila: null, ...extra };
}

/** Traduce una clasificación al estado que entiende la interfaz. */
function estadoDeClase(clase) {
    if (clase === CLASE.SESION) return 'sesion';
    if (clase === CLASE.DUPLICADO) return 'duplicado';
    return 'error';
}

/**
 * Alta de un apunte.
 *
 * Sin conexión: va directo a la cola.
 * Con conexión: se intenta el servidor. Solo un fallo de RED lo manda a la
 * cola; permiso, validación, sesión y desconocido se informan al usuario y
 * NO se encolan.
 */
export async function crearApunte(sb, { tabla, fila, cola, online = true }) {
    if (!online) {
        cola.encolar(TIPO.INSERTAR, tabla, fila);
        return resultado('pendiente', { fila, clase: CLASE.RED });
    }

    let error = null;
    try {
        const r = await sb.from(tabla).insert(fila);
        error = r?.error || null;
    } catch (e) {
        error = e;
    }

    if (!error) return resultado('servidor', { fila });

    const c = clasificarError(error, { online });

    if (c.clase === CLASE.DUPLICADO) {
        // El client_id ya estaba: el apunte se guardó en un intento anterior.
        return resultado('duplicado', { fila, clase: c.clase, mensaje: c.mensaje });
    }

    if (c.recuperable) {
        cola.encolar(TIPO.INSERTAR, tabla, fila);
        return resultado('pendiente', { fila, clase: c.clase, mensaje: c.mensaje });
    }

    return resultado(estadoDeClase(c.clase), { fila, clase: c.clase, mensaje: c.mensaje });
}

/**
 * Edición de un apunte con restauración del estado local.
 *
 * @param {object} opciones
 * @param {Array}  opciones.lista      array local (se muta en el sitio)
 * @param {string} opciones.id         id del apunte en `lista`
 * @param {object} opciones.cambios    columnas a escribir
 * @param {boolean} opciones.pendiente si el apunte todavía no llegó al servidor
 */
export async function editarApunte(sb, {
    tabla, lista, id, cambios, cola, online = true, pendiente = false,
}) {
    const idx = lista.findIndex((f) => String(f.id) === String(id));
    if (idx === -1) {
        return resultado('error', { clase: CLASE.DESCONOCIDO, mensaje: 'Ese apunte ya no está.' });
    }

    const anterior = { ...lista[idx] };
    const restaurar = () => { lista[idx] = anterior; };

    // Apunte todavía sin enviar: se reescribe su tarea, no hay servidor al que ir.
    if (pendiente) {
        lista[idx] = { ...anterior, ...cambios, pendiente: true };
        cola.editar(tabla, id, cambios, { clientId: anterior.client_id || id });
        return resultado('pendiente', { fila: lista[idx], clase: CLASE.RED });
    }

    lista[idx] = { ...anterior, ...cambios, pendiente: !online };

    if (!online) {
        cola.editar(tabla, id, cambios, { clientId: anterior.client_id });
        return resultado('pendiente', { fila: lista[idx], clase: CLASE.RED });
    }

    let error = null;
    let filas = null;
    try {
        const r = await sb.from(tabla).update(cambios).eq('id', id).select('id');
        error = r?.error || null;
        filas = r?.data || null;
    } catch (e) {
        error = e;
    }

    if (!error && filas && filas.length > 0) {
        lista[idx] = { ...anterior, ...cambios, pendiente: false };
        return resultado('servidor', { fila: lista[idx] });
    }

    if (!error) {
        // Sin error y sin filas: RLS lo oculta o ya no existe (R5).
        restaurar();
        return resultado('error', {
            clase: CLASE.PERMISO,
            mensaje: 'El apunte ya no existe o no puedes modificarlo. Se ha deshecho el cambio.',
        });
    }

    const c = clasificarError(error, { online });

    if (c.recuperable) {
        lista[idx] = { ...anterior, ...cambios, pendiente: true };
        cola.editar(tabla, id, cambios, { clientId: anterior.client_id });
        return resultado('pendiente', { fila: lista[idx], clase: c.clase, mensaje: c.mensaje });
    }

    restaurar();
    return resultado(estadoDeClase(c.clase), { clase: c.clase, mensaje: c.mensaje });
}

/** Borrado con restauración del estado local si el servidor lo rechaza. */
export async function borrarApunte(sb, {
    tabla, lista, id, cola, online = true, pendiente = false,
}) {
    const idx = lista.findIndex((f) => String(f.id) === String(id));
    if (idx === -1) {
        return resultado('error', { clase: CLASE.DESCONOCIDO, mensaje: 'Ese apunte ya no está.' });
    }

    const anterior = lista[idx];
    const restaurar = () => { lista.splice(idx, 0, anterior); };

    lista.splice(idx, 1);

    if (pendiente) {
        // Nunca llegó al servidor: basta con cancelar su tarea de alta.
        cola.borrar(tabla, id, { clientId: anterior.client_id || id });
        return resultado('servidor', { fila: anterior });
    }

    if (!online) {
        cola.borrar(tabla, id, { clientId: anterior.client_id });
        return resultado('pendiente', { fila: anterior, clase: CLASE.RED });
    }

    let error = null;
    let filas = null;
    try {
        const r = await sb.from(tabla).delete().eq('id', id).select('id');
        error = r?.error || null;
        filas = r?.data || null;
    } catch (e) {
        error = e;
    }

    if (!error) {
        if (filas && filas.length === 0) {
            // No había nada que borrar: o ya estaba borrado (bien), o RLS lo
            // oculta (mal). No se puede distinguir, así que se restaura y se
            // pide comprobar, en lugar de fingir que se ha borrado.
            restaurar();
            return resultado('error', {
                clase: CLASE.PERMISO,
                mensaje: 'No se ha borrado nada: el apunte ya no existe o no puedes borrarlo.',
            });
        }
        return resultado('servidor', { fila: anterior });
    }

    const c = clasificarError(error, { online });

    if (c.recuperable) {
        cola.borrar(tabla, id, { clientId: anterior.client_id });
        return resultado('pendiente', { fila: anterior, clase: c.clase, mensaje: c.mensaje });
    }

    restaurar();
    return resultado(estadoDeClase(c.clase), { clase: c.clase, mensaje: c.mensaje });
}

/**
 * Traslado de saldo entre grupos.
 *
 * Mismo criterio que `crearApunte`: sin conexión, o con un fallo de RED, va a
 * la cola; permiso, validación y sesión se informan y NO se encolan, porque
 * reintentarlos no arreglaría nada.
 *
 * La diferencia está en la clave de idempotencia: se genera UNA vez, antes de
 * llamar, y se reutiliza en cada reintento. Por eso un doble clic, una
 * reconexión o un vaciado de cola repetido no pueden trasladar dos veces.
 */
export async function trasladarSaldo(sb, { argumentos, cola, online = true }) {
    if (!online) {
        cola.encolarLlamada('trasladar_saldo', argumentos);
        return resultado('pendiente', { fila: argumentos, clase: CLASE.RED });
    }

    let error = null;
    let datos = null;
    try {
        const r = await sb.rpc('trasladar_saldo', argumentos);
        error = r?.error || null;
        datos = r?.data || null;
    } catch (e) {
        error = e;
    }

    if (!error) return resultado('servidor', { fila: datos || argumentos });

    const c = clasificarError(error, { online });

    if (c.clase === CLASE.DUPLICADO) {
        // La clave ya estaba: el traslado entró en un intento anterior.
        return resultado('duplicado', { fila: argumentos, clase: c.clase, mensaje: c.mensaje });
    }

    if (c.recuperable) {
        cola.encolarLlamada('trasladar_saldo', argumentos);
        return resultado('pendiente', { fila: argumentos, clase: c.clase, mensaje: c.mensaje });
    }

    return resultado(estadoDeClase(c.clase), { fila: argumentos, clase: c.clase, mensaje: c.mensaje });
}

/** Deshacer un traslado. No borra nada: el servidor compensa. */
export async function deshacerTraslado(sb, { transferId, online = true }) {
    if (!online) {
        return resultado('error', {
            clase: CLASE.RED,
            mensaje: 'Para deshacer un traslado hace falta conexión.',
        });
    }
    try {
        const { error } = await sb.rpc('revertir_traslado', { p_transfer_id: transferId });
        if (!error) return resultado('servidor', { fila: { id: transferId } });
        const c = clasificarError(error, { online });
        return resultado(estadoDeClase(c.clase), { clase: c.clase, mensaje: c.mensaje });
    } catch (e) {
        const c = clasificarError(e, { online });
        return resultado(estadoDeClase(c.clase), { clase: c.clase, mensaje: c.mensaje });
    }
}
