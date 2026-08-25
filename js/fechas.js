// ============================================================
//  Fechas
//  Módulo puro. `hoy` es inyectable para que las pruebas no
//  dependan del reloj de la máquina.
// ============================================================
import { LOCALE } from './config.js';

const diaLargo = new Intl.DateTimeFormat(LOCALE, { weekday: 'long', day: 'numeric', month: 'long' });

/** Fecha local en formato ISO corto (YYYY-MM-DD), sin desplazamiento de zona. */
export function hoyISO(ahora = new Date()) {
    const d = new Date(ahora.getTime());
    d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
    return d.toISOString().slice(0, 10);
}

export function ayerISO(ahora = new Date()) {
    const d = new Date(ahora.getTime());
    d.setDate(d.getDate() - 1);
    return hoyISO(d);
}

export function tituloDia(iso, ahora = new Date()) {
    if (iso === hoyISO(ahora)) return 'Hoy';
    if (iso === ayerISO(ahora)) return 'Ayer';
    const texto = diaLargo.format(new Date(iso + 'T12:00:00'));
    return texto.charAt(0).toUpperCase() + texto.slice(1);
}

const dosCifras = (n) => String(n).padStart(2, '0');

function valida(anio, mes, dia) {
    if (mes < 1 || mes > 12 || dia < 1 || dia > 31) return null;
    return anio + '-' + dosCifras(mes) + '-' + dosCifras(dia);
}

/**
 * Interpreta una fecha escrita de varias formas y la normaliza a YYYY-MM-DD.
 * Acepta ISO (2026-03-04), europeo (04/03/2026, 4-3-26) y separadores . - /
 * Devuelve null si no la reconoce.
 */
export function fechaDesde(bruto) {
    const t = String(bruto ?? '').trim();

    let m = t.match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
    if (m) return valida(m[1], Number(m[2]), Number(m[3]));

    m = t.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})/);
    if (m) {
        let dia = Number(m[1]);
        let mes = Number(m[2]);
        const anio = m[3].length === 2 ? '20' + m[3] : m[3];
        // 25/12/2026 no puede ser mes 25: se entiende como día/mes.
        if (mes > 12 && dia <= 12) { const cambio = dia; dia = mes; mes = cambio; }
        return valida(anio, mes, dia);
    }

    return null;
}
