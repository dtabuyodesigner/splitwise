// ============================================================
//  Clasificación de errores de escritura
//
//  Corrige el riesgo R2: en el monolito original, cualquier error de
//  Supabase acababa en la cola offline con el mensaje "se enviará con
//  conexión". Solo los fallos REALMENTE recuperables deben encolarse.
//
//  Módulo puro.
// ============================================================

export const CLASE = {
    /** Red caída, timeout, 5xx, 429. Reintentable: entra en la cola. */
    RED: 'red',
    /** JWT caducado o ausente (401, PGRST301...). Hay que volver a entrar. */
    SESION: 'sesion',
    /** RLS o GRANT lo prohíben (42501, 403). Reintentar no sirve de nada. */
    PERMISO: 'permiso',
    /** CHECK, NOT NULL, FK, tipo inválido. El dato es incorrecto. */
    VALIDACION: 'validacion',
    /** Violación de unicidad: la fila YA existe. No es un fallo real. */
    DUPLICADO: 'duplicado',
    /** No encaja en ninguna de las anteriores. No se encola. */
    DESCONOCIDO: 'desconocido',
};

/** Solo esta clase puede entrar en la cola offline. */
export function esRecuperable(clase) {
    return clase === CLASE.RED;
}

const CODIGOS_PERMISO = new Set(['42501']);
const CODIGOS_SESION = new Set(['PGRST301', '401']);
const CODIGOS_VALIDACION = new Set([
    '23502', // not_null_violation
    '23503', // foreign_key_violation
    '23514', // check_violation
    '22P02', // invalid_text_representation
    '22003', // numeric_value_out_of_range
    '22007', // invalid_datetime_format
    '22008', // datetime_field_overflow
    'PGRST204', // columna inexistente en el cuerpo
]);

function textoDe(error) {
    return [error?.message, error?.details, error?.hint, error?.error_description, error?.error]
        .filter(Boolean).join(' ').toLowerCase();
}

function estadoDe(error) {
    const n = Number(error?.status ?? error?.statusCode ?? error?.code);
    return Number.isFinite(n) && n >= 100 && n < 600 ? n : null;
}

/**
 * @param {unknown} error  error de supabase-js, PostgrestError o excepción nativa
 * @param {{online?: boolean}} contexto
 * @returns {{clase: string, recuperable: boolean, codigo: string|null, mensaje: string}}
 */
export function clasificarError(error, contexto = {}) {
    const online = contexto.online !== false;
    const codigo = error?.code != null ? String(error.code) : null;
    const estado = estadoDe(error);
    const texto = textoDe(error);
    const nombre = String(error?.name || '');

    const decidir = (clase) => ({
        clase,
        recuperable: esRecuperable(clase),
        codigo,
        mensaje: mensajeDeClase(clase, error),
    });

    // 1. Sin conexión declarada por el navegador: siempre recuperable.
    if (!online) return decidir(CLASE.RED);

    // 2. Fallos de transporte. `fetch` lanza TypeError cuando la petición no
    //    llega a salir; supabase-js lo propaga como "Failed to fetch" / "Load failed".
    if (nombre === 'TypeError' || nombre === 'AbortError' || nombre === 'TimeoutError') {
        return decidir(CLASE.RED);
    }
    if (/failed to fetch|networkerror|network error|load failed|fetch failed|econnrefused|enotfound|etimedout|socket hang up|timeout|aborted/.test(texto)) {
        return decidir(CLASE.RED);
    }
    if (estado === 408 || estado === 425 || estado === 429 || (estado !== null && estado >= 500)) {
        return decidir(CLASE.RED);
    }

    // 3. Unicidad: la fila ya está. Se trata aparte porque NO es un fallo.
    if (codigo === '23505' || /duplicate key|already exists/.test(texto)) {
        return decidir(CLASE.DUPLICADO);
    }

    // 4. Sesión caducada. Se comprueba antes que permiso porque PGRST301 es
    //    "JWT expired" y no un problema de política.
    if (estado === 401 || CODIGOS_SESION.has(codigo) ||
        /jwt expired|jwt is expired|invalid jwt|missing sub claim|no api key|refresh token|token is expired|not authenticated/.test(texto)) {
        return decidir(CLASE.SESION);
    }

    // 5. RLS / permisos.
    if (estado === 403 || CODIGOS_PERMISO.has(codigo) ||
        /row-level security|row level security|violates row-level|permission denied|insufficient privilege|not allowed/.test(texto)) {
        return decidir(CLASE.PERMISO);
    }

    // 6. Validación y restricciones.
    if (CODIGOS_VALIDACION.has(codigo) || (codigo && /^(22|23)/.test(codigo)) ||
        estado === 400 || estado === 409 || estado === 422 ||
        /violates check constraint|violates foreign key|violates not-null|invalid input syntax|out of range/.test(texto)) {
        return decidir(CLASE.VALIDACION);
    }

    return decidir(CLASE.DESCONOCIDO);
}

const MENSAJES = {
    [CLASE.RED]: 'Sin conexión con el servidor.',
    [CLASE.SESION]: 'Tu sesión ha caducado. Vuelve a entrar para guardar esto.',
    [CLASE.PERMISO]: 'No tienes permiso para hacer este cambio en este grupo.',
    [CLASE.VALIDACION]: 'El servidor ha rechazado los datos.',
    [CLASE.DUPLICADO]: 'Ese apunte ya estaba guardado.',
    [CLASE.DESCONOCIDO]: 'Algo ha fallado y no se ha guardado.',
};

function mensajeDeClase(clase, error) {
    const base = MENSAJES[clase];
    const detalle = error?.message ? String(error.message) : '';
    if (clase === CLASE.VALIDACION && detalle) return base + ' ' + detalle;
    if (clase === CLASE.DESCONOCIDO && detalle) return base + ' ' + detalle;
    return base;
}

/** Mensajes de la pantalla de acceso. Se conserva del monolito original. */
export function traducirError(error) {
    const m = (error?.message || '').toLowerCase();
    if (m.includes('invalid login')) return 'El correo o la contraseña no son correctos.';
    if (m.includes('already registered')) return 'Ese correo ya tiene cuenta. Entra en lugar de crearla.';
    if (m.includes('password should be')) return 'La contraseña necesita al menos 6 caracteres.';
    if (m.includes('email not confirmed')) return 'Confirma el correo desde el enlace que te ha llegado.';
    if (m.includes('signups not allowed')) return 'El alta de cuentas nuevas está cerrada en Supabase.';
    if (m.includes('provider is not enabled')) return 'Google todavía no está activado en Supabase.';
    if (m.includes('failed to fetch')) return 'Sin conexión con el servidor. Revisa la red.';
    return error?.message || 'Algo ha fallado. Inténtalo otra vez.';
}

/**
 * Mensaje para el usuario según lo que ha pasado de verdad al guardar.
 * Los cuatro estados que pide el encargo, más el duplicado.
 */
export function mensajeResultado(resultado, { sustantivo = 'Gasto' } = {}) {
    switch (resultado.estado) {
        case 'servidor':   return sustantivo + ' guardado';
        case 'pendiente':  return sustantivo + ' pendiente · sin conexión, se enviará solo';
        case 'duplicado':  return sustantivo + ' ya estaba guardado';
        case 'sesion':     return 'Sesión caducada · vuelve a entrar para guardarlo';
        case 'error':      return resultado.mensaje || 'No se ha podido guardar';
        default:           return 'No se ha podido guardar';
    }
}
