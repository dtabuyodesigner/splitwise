// ============================================================
//  Importes: lectura, redondeo y formato
//  Módulo puro.
// ============================================================
import { LOCALE, CURRENCY } from './config.js';

const dinero = new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY });

export function formatoDinero(n) {
    return dinero.format(Number(n) || 0);
}

/** Redondeo a céntimos, estable frente a la representación binaria. */
export function aCentimos(n) {
    const x = Number(n);
    if (!Number.isFinite(x)) return NaN;
    // El épsilon corrige casos como 1.005 → 1.00 por representación binaria.
    return Math.round((x + (x >= 0 ? 1 : -1) * Number.EPSILON * Math.abs(x)) * 100);
}

export function redondear2(n) {
    const c = aCentimos(n);
    return Number.isFinite(c) ? c / 100 : NaN;
}

// ------------------------------------------------------------
//  Evaluador aritmético
//  Sustituye al `Function()` del monolito original (riesgo R9).
//  Gramática: expr := term (('+'|'-') term)*
//             term := factor (('*'|'/') factor)*
//             factor := '-'? ( numero | '(' expr ')' )
// ------------------------------------------------------------
function evaluarAritmetica(entrada) {
    const fichas = String(entrada).match(/\d+(?:\.\d+)?|[+\-*/()]/g);
    if (!fichas) return NaN;
    // Descarta entradas con caracteres que el tokenizador habría ignorado.
    if (fichas.join('') !== String(entrada).replace(/\s+/g, '')) return NaN;

    let i = 0;
    const mirar = () => fichas[i];
    const comer = () => fichas[i++];

    function factor() {
        if (mirar() === '-') { comer(); const v = factor(); return Number.isFinite(v) ? -v : NaN; }
        if (mirar() === '+') { comer(); return factor(); }
        if (mirar() === '(') {
            comer();
            const v = expr();
            if (comer() !== ')') return NaN;
            return v;
        }
        const f = comer();
        if (f === undefined || !/^\d/.test(f)) return NaN;
        return Number(f);
    }

    function term() {
        let v = factor();
        while (mirar() === '*' || mirar() === '/') {
            const op = comer();
            const d = factor();
            if (!Number.isFinite(v) || !Number.isFinite(d)) return NaN;
            v = op === '*' ? v * d : (d === 0 ? NaN : v / d);
        }
        return v;
    }

    function expr() {
        let v = term();
        while (mirar() === '+' || mirar() === '-') {
            const op = comer();
            const d = term();
            if (!Number.isFinite(v) || !Number.isFinite(d)) return NaN;
            v = op === '+' ? v + d : v - d;
        }
        return v;
    }

    const valor = expr();
    return i === fichas.length ? valor : NaN;
}

/**
 * Interpreta un importe escrito por una persona: "12,50", "1.234,56",
 * "1,234.56", "15 + 4,20 + 8", "12 €".
 * Devuelve NaN si no es interpretable.
 */
export function aNumero(texto) {
    if (typeof texto === 'number') {
        return Number.isFinite(texto) ? redondear2(texto) : NaN;
    }

    let t = String(texto ?? '').replace(/[€$\s]/g, '').trim();
    if (!t) return NaN;

    if (/[+\-*/]/.test(t.slice(1)) && /^[0-9+\-*/().,]+$/.test(t)) {
        const res = evaluarAritmetica(t.replace(/,/g, '.'));
        if (Number.isFinite(res)) return redondear2(res);
    }

    const punto = t.includes('.');
    const coma = t.includes(',');

    if (punto && coma) {
        if (t.lastIndexOf(',') > t.lastIndexOf('.')) t = t.replace(/\./g, '').replace(',', '.');
        else t = t.replace(/,/g, '');
    } else if (coma) {
        t = /^\d{1,3}(,\d{3})+$/.test(t) ? t.replace(/,/g, '') : t.replace(',', '.');
    } else if (punto) {
        if (/^\d{1,3}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, '');
    }

    const n = parseFloat(t);
    return Number.isFinite(n) ? redondear2(n) : NaN;
}
