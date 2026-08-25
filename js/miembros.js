// ============================================================
//  Pertenencia a grupos
//
//  Regla de negocio (confirmada por Dani):
//   · `group_members` es la ÚNICA fuente de verdad de quién está en un grupo.
//   · Un grupo puede tener 1, 2 o más miembros.
//   · Registrarse NO mete a nadie en ningún grupo.
//   · Crear un grupo mete SOLO a su creador, como propietario.
//   · Un grupo individual, con un único propietario, es válido.
//
//  Módulo puro.
// ============================================================

/** Cómo se está resolviendo la pertenencia. */
export const MODO = {
    /** `group_members` todavía no existe: comportamiento anterior a la migración. */
    HEREDADO: 'heredado',
    /** `group_members` manda. */
    PERTENENCIA: 'pertenencia',
};

/** Qué clase de grupo es, a efectos de qué puede calcular la interfaz. */
export const TIPO = {
    /** No hay grupo activo. */
    NINGUNO: 'ninguno',
    /** El grupo existe pero no soy miembro: no debería ni verse. */
    AJENO: 'ajeno',
    /** Un solo miembro. Funciona; no hay reparto y el saldo es 0. */
    SOLO: 'solo',
    /** Exactamente dos. Es el caso para el que está hecho el cálculo actual. */
    PAR: 'par',
    /** Tres o más. El reparto múltiple todavía no existe: NO se calcula saldo. */
    MULTI: 'multi',
};

/** `null` = la tabla no existe todavía. Un array vacío SÍ es un dato. */
export function modoDe(membresias) {
    return Array.isArray(membresias) ? MODO.PERTENENCIA : MODO.HEREDADO;
}

/**
 * Ids de los miembros de un grupo.
 *
 * En modo heredado no hay tabla de pertenencia, así que se conserva el
 * supuesto anterior —todos los perfiles visibles— únicamente para que la app
 * siga funcionando antes de aplicar la migración.
 */
export function miembrosDeGrupo(grupoId, { membresias = null, perfiles = [] } = {}) {
    if (Array.isArray(membresias)) {
        const ids = membresias
            .filter((m) => String(m.group_id) === String(grupoId))
            .map((m) => m.user_id);
        return [...new Set(ids)];
    }
    return perfiles.map((p) => p.id);
}

/**
 * Clasifica el grupo activo.
 *
 * Es la función de la que cuelga todo lo demás: qué se puede calcular y qué
 * hay que decir en pantalla. Nunca devuelve PAR si no hay exactamente dos
 * personas identificadas, para que no se pueda enseñar un saldo inventado.
 */
export function tipoDeGrupo(grupoId, { membresias = null, perfiles = [], yoId } = {}) {
    if (grupoId == null || !yoId) return TIPO.NINGUNO;

    const ids = miembrosDeGrupo(grupoId, { membresias, perfiles });

    if (Array.isArray(membresias) && !ids.includes(yoId)) return TIPO.AJENO;

    if (ids.length <= 1) return TIPO.SOLO;
    if (ids.length === 2) return TIPO.PAR;
    return TIPO.MULTI;
}

/**
 * "La otra persona" del grupo, SOLO cuando el grupo es un par.
 *
 * Devuelve `null` para un grupo individual y para uno de tres o más: en esos
 * casos no existe "la otra persona", y elegir una arbitrariamente es
 * exactamente lo que producía saldos incorrectos (riesgo R1).
 */
export function otroDelGrupo(grupoId, { membresias = null, perfiles = [], yoId } = {}) {
    if (tipoDeGrupo(grupoId, { membresias, perfiles, yoId }) !== TIPO.PAR) return null;

    const otros = miembrosDeGrupo(grupoId, { membresias, perfiles })
        .filter((id) => id !== yoId);
    if (otros.length !== 1) return null;

    return perfiles.find((p) => p.id === otros[0]) || null;
}

/** Perfiles de todos los miembros del grupo, en orden estable. */
export function perfilesDelGrupo(grupoId, { membresias = null, perfiles = [], yoId } = {}) {
    const ids = miembrosDeGrupo(grupoId, { membresias, perfiles });
    const encontrados = ids
        .map((id) => perfiles.find((p) => p.id === id))
        .filter(Boolean);
    // Uno mismo primero: es como se pinta en toda la interfaz.
    return encontrados.sort((a, b) => (a.id === yoId ? -1 : b.id === yoId ? 1 : 0));
}

/**
 * Grupos visibles.
 *
 * En modo pertenencia son EXACTAMENTE aquellos donde el usuario tiene una
 * fila en `group_members`. Sin excepciones: no pertenecer es no ver.
 */
export function gruposVisibles(grupos, { membresias = null, yoId } = {}) {
    if (!Array.isArray(membresias)) return grupos;
    if (!yoId) return [];

    const mios = new Set(
        membresias.filter((m) => m.user_id === yoId).map((m) => String(m.group_id))
    );
    return grupos.filter((g) => mios.has(String(g.id)));
}

/** ¿Es esta persona propietaria del grupo? */
export function esPropietario(grupoId, { membresias = null, yoId } = {}) {
    if (!Array.isArray(membresias) || !yoId) return false;
    return membresias.some(
        (m) => String(m.group_id) === String(grupoId) && m.user_id === yoId && m.role === 'owner'
    );
}

/** Aviso que debe leer el usuario, o null si el grupo se maneja con normalidad. */
export function avisoDeTipo(tipo, cuantos = 0) {
    if (tipo === TIPO.MULTI) {
        return 'Este grupo tiene más de dos participantes; el reparto múltiple ' +
               'todavía no está disponible.';
    }
    if (tipo === TIPO.AJENO) {
        return 'No perteneces a este grupo.';
    }
    return null;
}
