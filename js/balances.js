// ============================================================
//  Cálculo de saldos
//  Módulo puro: recibe listas y devuelve números. No lee estado global.
//
//  Convención de signo (la misma que el monolito original):
//    saldo > 0  →  la otra persona te debe a ti
//    saldo < 0  →  tú le debes a la otra persona
//
//  `payer_share` es la fracción del gasto que asume QUIEN PAGÓ.
//    1.0 → el gasto es solo suyo, nadie le debe nada
//    0.5 → a medias
//    0.0 → el gasto es solo del otro, le debe el importe entero
// ============================================================
import { aCentimos } from './dinero.js';

/** Filtra por grupo comparando como texto: los id pueden ser uuid o número. */
export function delGrupo(filas, grupoId) {
    if (grupoId == null) return [];
    return filas.filter((f) => String(f.group_id) === String(grupoId));
}

/**
 * Saldo neto de `yoId` frente a `otroId` en un conjunto ya filtrado por grupo.
 *
 * Se acumula en céntimos enteros y se redondea una sola vez al final: así el
 * resultado no arrastra deriva binaria aunque haya decenas de miles de gastos.
 *
 * Devuelve `null` si no hay dos personas identificadas: es preferible no
 * enseñar saldo a enseñar uno inventado (riesgo R1).
 *
 * @param {Array} gastos         filas de expenses del grupo
 * @param {Array} liquidaciones  filas de settlements del grupo
 * @param {{yoId: string, otroId: string}} personas
 * @returns {number|null} euros
 */
export function calcularSaldo(gastos, liquidaciones, { yoId, otroId } = {}) {
    if (!yoId || !otroId || yoId === otroId) return null;

    let centimos = 0;

    for (const g of gastos) {
        const importe = aCentimos(g.amount);
        const parte = Number(g.payer_share);
        if (!Number.isFinite(importe) || !Number.isFinite(parte)) continue;

        // Lo que el NO pagador debe al pagador por este gasto.
        const deuda = importe * (1 - parte);

        if (g.paid_by === yoId) centimos += deuda;
        else if (g.paid_by === otroId) centimos -= deuda;
        // Un gasto pagado por alguien ajeno al par no altera el saldo entre
        // estas dos personas. El monolito original lo repartía contra un
        // tercero arbitrario; aquí se ignora explícitamente.
    }

    for (const l of liquidaciones) {
        const importe = aCentimos(l.amount);
        if (!Number.isFinite(importe)) continue;

        // Quien paga reduce su deuda; quien cobra reduce lo que le deben.
        if (l.from_user === yoId && l.to_user === otroId) centimos += importe;
        else if (l.from_user === otroId && l.to_user === yoId) centimos -= importe;
    }

    return Math.round(centimos) / 100;
}

/** Total gastado en el grupo y cuánto ha adelantado cada persona. */
export function totalesDelGrupo(gastos, perfiles = []) {
    let totalCentimos = 0;
    const adelantado = {};
    for (const p of perfiles) adelantado[p.id] = 0;

    for (const g of gastos) {
        const importe = aCentimos(g.amount);
        if (!Number.isFinite(importe)) continue;
        totalCentimos += importe;
        adelantado[g.paid_by] = (adelantado[g.paid_by] || 0) + importe;
    }

    for (const id of Object.keys(adelantado)) adelantado[id] = adelantado[id] / 100;
    return { total: totalCentimos / 100, adelantado };
}

/** Suma de importes en euros, sin deriva binaria. */
export function sumar(filas, campo = 'amount') {
    let c = 0;
    for (const f of filas) {
        const v = aCentimos(f[campo]);
        if (Number.isFinite(v)) c += v;
    }
    return Math.round(c) / 100;
}

/** Reparto por categoría, ordenado de mayor a menor. */
export function porCategoria(gastos) {
    const suma = {};
    for (const g of gastos) {
        const cat = g.category || 'otros';
        const v = aCentimos(g.amount);
        if (!Number.isFinite(v)) continue;
        suma[cat] = (suma[cat] || 0) + v;
    }
    return Object.entries(suma)
        .map(([cat, c]) => [cat, c / 100])
        .filter(([, v]) => v > 0)
        .sort((a, b) => b[1] - a[1]);
}
