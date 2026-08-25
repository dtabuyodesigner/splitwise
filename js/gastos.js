// ============================================================
//  Construcción y validación de la fila de un gasto
//
//  Existe para que la comprobación NO dependa de lo que haya pintado el
//  formulario. El fallo que corrige: la hoja validaba el grupo activo pero
//  escribía el grupo elegido en un `<select>`, así que se podía abrir desde
//  un grupo de dos y guardar en uno individual o de tres.
//
//  En esta fase el grupo de un gasto es INMUTABLE: al crear sale del grupo
//  activo, y al editar se conserva el del propio gasto. Mover un gasto de
//  grupo será una operación explícita en otra fase.
//
//  Módulo puro.
// ============================================================
import { TIPO } from './miembros.js';
import { redondear2 } from './dinero.js';

export const RECHAZO = {
    SIN_GRUPO: 'sin-grupo',
    AJENO: 'ajeno',
    MULTI: 'multi',
    PAGADOR: 'pagador',
    REPARTO: 'reparto',
    IMPORTE: 'importe',
    CONCEPTO: 'concepto',
};

const MENSAJES = {
    [RECHAZO.SIN_GRUPO]: 'No hay ningún grupo donde guardar este gasto.',
    [RECHAZO.AJENO]: 'No perteneces a este grupo.',
    [RECHAZO.MULTI]: 'Este grupo tiene más de dos participantes; el reparto múltiple ' +
                     'todavía no está disponible, así que no se pueden apuntar gastos aquí.',
    [RECHAZO.PAGADOR]: 'Quien pagó tiene que ser miembro del grupo.',
    [RECHAZO.REPARTO]: 'El porcentaje tiene que estar entre 0 y 100.',
    [RECHAZO.IMPORTE]: 'Escribe un importe mayor que cero.',
    [RECHAZO.CONCEPTO]: 'Falta decir en qué fue el gasto.',
};

const rechazar = (motivo) => ({ ok: false, motivo, mensaje: MENSAJES[motivo], fila: null });

/**
 * Decide el grupo de destino y devuelve la fila lista para guardar, o el
 * motivo por el que no se puede.
 *
 * @param {object} opciones
 * @param {string|null} opciones.grupoActivo    grupo desde el que se abre la hoja
 * @param {object|null} opciones.gastoExistente fila que se está editando, si la hay
 * @param {string} opciones.tipoGrupo           tipo del grupo DESTINO, ya resuelto
 * @param {string[]} opciones.miembros          ids de los miembros del grupo destino
 * @param {string} opciones.yoId
 * @param {{pagador: string, reparto: number}} opciones.formulario
 * @param {{importe:number, concepto:string, categoria:string, fecha:string}} opciones.datos
 */
export function prepararFilaGasto({
    grupoActivo = null,
    gastoExistente = null,
    tipoGrupo,
    miembros = [],
    yoId = null,
    formulario = {},
    datos = {},
} = {}) {
    // 1. El grupo de destino NO sale del formulario.
    //    Al editar manda el del propio gasto; al crear, el grupo activo.
    const destino = gastoExistente ? gastoExistente.group_id : grupoActivo;
    if (destino == null || destino === '') return rechazar(RECHAZO.SIN_GRUPO);

    // 2. Datos básicos.
    const importe = Number(datos.importe);
    if (!Number.isFinite(importe) || importe <= 0) return rechazar(RECHAZO.IMPORTE);

    const concepto = String(datos.concepto ?? '').trim();
    if (!concepto) return rechazar(RECHAZO.CONCEPTO);

    // 3. Qué admite el grupo de destino. Se comprueba aquí, no en la hoja:
    //    la hoja pudo abrirse sobre otro grupo distinto.
    if (tipoGrupo === TIPO.AJENO) return rechazar(RECHAZO.AJENO);
    if (tipoGrupo === TIPO.MULTI) return rechazar(RECHAZO.MULTI);
    if (tipoGrupo !== TIPO.SOLO && tipoGrupo !== TIPO.PAR) return rechazar(RECHAZO.SIN_GRUPO);

    let paidBy = formulario.pagador ?? null;

    // Exigir un número de verdad, no coaccionar. `Number(null)` y `Number('')`
    // valen 0, y 0 es un reparto VÁLIDO con significado propio: «el gasto es
    // entero de la otra persona». Un reparto ausente no puede convertirse en
    // eso por accidente.
    let reparto = typeof formulario.reparto === 'number' ? formulario.reparto : NaN;

    if (tipoGrupo === TIPO.SOLO) {
        // En un grupo individual el gasto es entero de quien lo apunta.
        // Se fuerza EN EL DATO, no solo en la interfaz: da igual lo que
        // hayan puesto los controles o lo que alguien manipule desde fuera.
        if (!yoId) return rechazar(RECHAZO.PAGADOR);
        paidBy = yoId;
        reparto = 1;
    } else {
        // PAR: el pagador tiene que ser miembro de ESTE grupo.
        if (!paidBy || (miembros.length && !miembros.includes(paidBy))) {
            return rechazar(RECHAZO.PAGADOR);
        }
        if (!Number.isFinite(reparto) || reparto < 0 || reparto > 1) {
            return rechazar(RECHAZO.REPARTO);
        }
    }

    return {
        ok: true,
        motivo: null,
        mensaje: null,
        fila: {
            group_id: destino,
            paid_by: paidBy,
            amount: redondear2(importe),
            description: concepto,
            category: datos.categoria || 'otros',
            payer_share: reparto,
            spent_on: datos.fecha,
        },
    };
}
