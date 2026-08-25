// ============================================================
//  Trasladar saldo entre grupos
//  Módulo puro: recibe listas y devuelve datos. No toca el DOM ni la red.
//
//  El servidor es quien manda: `trasladar_saldo()` recalcula el saldo y
//  nunca acepta el importe del navegador. Todo lo que hay aquí es para que
//  la persona vea lo que va a pasar ANTES de confirmarlo, y para no ofrecer
//  destinos imposibles.
// ============================================================
import { calcularSaldo, delGrupo } from './balances.js';
import { TIPO, otroDelGrupo, tipoDeGrupo } from './miembros.js';

/** Papeles que `0007` pone en `settlements.transfer_role`. */
export const ROL = {
    ORIGEN: 'origen',
    DESTINO: 'destino',
    REVERSION_ORIGEN: 'reversion_origen',
    REVERSION_DESTINO: 'reversion_destino',
};

/** Un movimiento de traslado no es un pago: se enseña distinto. */
export function esMovimientoDeTraslado(liquidacion) {
    return Boolean(liquidacion && liquidacion.transfer_id && liquidacion.transfer_role);
}

/**
 * Qué texto lleva un movimiento de traslado en la lista.
 * Sin esto diría «Pago de X a Y», que en el destino es justo lo contrario
 * de lo que ha pasado: allí la deuda se crea, no se salda.
 */
export function tituloDeTraslado(liquidacion, { nombreOrigen, nombreDestino } = {}) {
    switch (liquidacion.transfer_role) {
        case ROL.ORIGEN:
            return nombreDestino ? `Saldo trasladado a ${nombreDestino}` : 'Saldo trasladado a otro grupo';
        case ROL.DESTINO:
            return nombreOrigen ? `Saldo procedente de ${nombreOrigen}` : 'Saldo procedente de otro grupo';
        case ROL.REVERSION_ORIGEN:
        case ROL.REVERSION_DESTINO:
            return 'Traslado deshecho';
        default:
            return 'Traslado de saldo';
    }
}

/**
 * Saldo de un grupo tal y como lo verá el servidor.
 * Devuelve `null` si el grupo no es PAR: el traslado solo existe entre dos
 * personas, y con más el reparto todavía no está implementado.
 *
 * @returns {{euros: number, deudor: string, acreedor: string}|null}
 */
export function deudaDelGrupo(grupoId, { gastos, liquidaciones, membresias, perfiles = [], yoId }) {
    if (!grupoId || !yoId) return null;
    if (tipoDeGrupo(grupoId, { membresias, perfiles, yoId }) !== TIPO.PAR) return null;

    // `otroDelGrupo` devuelve el PERFIL, no el id.
    const otroPerfil = otroDelGrupo(grupoId, { membresias, perfiles, yoId });
    if (!otroPerfil) return null;
    const otro = otroPerfil.id;

    const saldo = calcularSaldo(
        delGrupo(gastos, grupoId),
        delGrupo(liquidaciones, grupoId),
        { yoId, otroId: otro },
    );
    if (saldo == null || saldo === 0) return null;

    // saldo > 0 → el otro me debe a mí. saldo < 0 → yo le debo.
    return saldo > 0
        ? { euros: saldo, deudor: otro, acreedor: yoId }
        : { euros: -saldo, deudor: yoId, acreedor: otro };
}

/**
 * Grupos a los que se puede trasladar desde `origenId`.
 *
 * Solo los que tienen EXACTAMENTE a las mismas dos personas. El servidor lo
 * vuelve a comprobar; esto es para no ofrecer lo que va a rechazar.
 */
export function destinosValidos(origenId, { membresias, perfiles = [], yoId, grupos = [] }) {
    if (!origenId || !yoId) return [];
    if (tipoDeGrupo(origenId, { membresias, perfiles, yoId }) !== TIPO.PAR) return [];

    const otro = otroDelGrupo(origenId, { membresias, perfiles, yoId });
    if (!otro) return [];

    return grupos.filter((g) => {
        const id = g && g.id;
        if (!id || String(id) === String(origenId)) return false;
        if (tipoDeGrupo(id, { membresias, perfiles, yoId }) !== TIPO.PAR) return false;
        const suyo = otroDelGrupo(id, { membresias, perfiles, yoId });
        return Boolean(suyo) && String(suyo.id) === String(otro.id);
    });
}

/**
 * Valida lo que la persona ha pedido, antes de molestar al servidor.
 *
 * Devuelve `{ ok: true, importe }` o `{ ok: false, motivo }`. El motivo es
 * el texto que se le enseña: por eso está en castellano y no es un código.
 */
export function validarTraslado({ origenId, destinoId, importe, deuda }) {
    if (!origenId) return { ok: false, motivo: 'No hay grupo de origen.' };
    if (!destinoId) return { ok: false, motivo: 'Elige un grupo de destino.' };
    if (String(origenId) === String(destinoId)) {
        return { ok: false, motivo: 'El destino tiene que ser un grupo distinto del origen.' };
    }
    if (!deuda || !(deuda.euros > 0)) {
        return { ok: false, motivo: 'Este grupo no tiene ninguna deuda que trasladar.' };
    }

    // `null` o `undefined` significan «todo». Un importe escrito sí se valida.
    if (importe == null || importe === '') {
        return { ok: true, importe: null };
    }

    const n = typeof importe === 'number' ? importe : Number(String(importe).replace(',', '.'));
    if (!Number.isFinite(n)) return { ok: false, motivo: 'El importe no es un número.' };

    // Se compara en céntimos enteros: 0.1 + 0.2 no vale para esto.
    const cent = Math.round(n * 100);
    const tope = Math.round(deuda.euros * 100);
    if (cent <= 0) return { ok: false, motivo: 'El importe tiene que ser mayor que cero.' };
    if (cent > tope) {
        return { ok: false, motivo: `No puedes trasladar más de ${(tope / 100).toFixed(2)} €.` };
    }

    return { ok: true, importe: cent === tope ? null : cent / 100 };
}

/**
 * Los argumentos de la llamada, con su clave de idempotencia.
 *
 * La clave se genera UNA vez por acción de la persona y se reutiliza en cada
 * reintento: es lo que hace que un doble clic o una reconexión no trasladen
 * dos veces. Nunca se regenera al reintentar.
 */
export function argumentosDeTraslado({ origenId, destinoId, importe, clave }) {
    return {
        p_grupo_origen: origenId,
        p_grupo_destino: destinoId,
        p_idempotency_key: clave,
        p_importe: importe == null ? null : Number(importe),
    };
}

/** Resumen de lo que va a pasar, para la confirmación. */
export function resumenDeTraslado({ deuda, importe, nombreOrigen, nombreDestino, nombre }) {
    const cuanto = importe == null ? deuda.euros : importe;
    const restante = Math.round((deuda.euros - cuanto) * 100) / 100;
    return {
        cuanto,
        restante,
        total: importe == null,
        deudor: nombre(deuda.deudor),
        acreedor: nombre(deuda.acreedor),
        nombreOrigen,
        nombreDestino,
    };
}
