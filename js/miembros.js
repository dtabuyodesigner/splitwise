// ============================================================
//  Pertenencia a grupos
//
//  Puente entre el modelo actual (dos usuarios globales, sin tabla de
//  membresía) y el modelo objetivo (`group_members`), para que el mismo
//  código funcione antes y después de aplicar la migración.
//
//  Módulo puro.
// ============================================================

/**
 * Ids de los miembros de un grupo.
 * Si no hay datos de membresía (la tabla todavía no existe), se cae al
 * comportamiento heredado: todos los perfiles visibles son del grupo.
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
 * "La otra persona" del grupo activo.
 *
 * Con `group_members` disponible se resuelve por pertenencia real. Si el grupo
 * no tiene exactamente dos miembros se devuelve `null`: la interfaz de esta
 * fase está diseñada para pares, y es preferible no enseñar saldo a enseñar
 * uno calculado contra un tercero arbitrario (riesgo R1).
 *
 * Sin `group_members`, se conserva la heurística original.
 */
export function otroDelGrupo(grupoId, { membresias = null, perfiles = [], yoId } = {}) {
    if (!yoId) return null;

    if (Array.isArray(membresias)) {
        const ids = miembrosDeGrupo(grupoId, { membresias, perfiles });
        if (!ids.includes(yoId)) return null;
        const otros = ids.filter((id) => id !== yoId);
        if (otros.length !== 1) return null;
        return perfiles.find((p) => p.id === otros[0]) || null;
    }

    const otros = perfiles.filter((p) => p.id !== yoId);
    if (otros.length !== 1) return null;
    return otros[0];
}

/** Grupos visibles para el usuario, según la membresía si la hay. */
export function gruposVisibles(grupos, { membresias = null, yoId } = {}) {
    if (!Array.isArray(membresias) || !yoId) return grupos;
    const mios = new Set(
        membresias.filter((m) => m.user_id === yoId).map((m) => String(m.group_id))
    );
    return grupos.filter((g) => mios.has(String(g.id)));
}
