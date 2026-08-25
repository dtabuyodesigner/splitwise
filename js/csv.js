// ============================================================
//  Importación y exportación CSV
//  Módulo puro: el contexto (perfiles, grupo activo, quién soy) se inyecta.
// ============================================================
import { CATEGORIES, PISTAS_CATEGORIA } from './config.js';
import { aNumero } from './dinero.js';
import { fechaDesde, hoyISO } from './fechas.js';

export const COLUMNAS = {
    fecha:     ['fecha', 'date', 'dia', 'day'],
    tipo:      ['tipo', 'type'],
    concepto:  ['concepto', 'descripcion', 'description', 'detalle', 'nombre', 'que', 'item'],
    categoria: ['categoria', 'category', 'tipo de gasto'],
    pago:      ['pago', 'pagador', 'pagadora', 'pagado por', 'quien pago', 'quien paga',
                'paga', 'persona', 'paid by', 'payer', 'who paid', 'quien'],
    reparto:   ['reparto', 'split', 'division', 'reparticion'],
    importe:   ['importe', 'cantidad', 'coste', 'costo', 'precio', 'total',
                'amount', 'cost', 'price', 'gasto'],
};

export function sinTildes(t) {
    return String(t ?? '')
        .toLowerCase()
        .normalize('NFD')
        .replace(/[\u0300-\u036f]/g, '')
        .trim();
}

export function escaparRegex(t) {
    return String(t).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Troceador de CSV con comillas dobles y escapado "" según RFC 4180. */
export function trocearCSV(texto, separador) {
    const filas = [];
    let fila = [];
    let campo = '';
    let dentroComillas = false;

    for (let i = 0; i < texto.length; i++) {
        const c = texto[i];

        if (dentroComillas) {
            if (c === '"') {
                if (texto[i + 1] === '"') { campo += '"'; i++; }
                else dentroComillas = false;
            } else {
                campo += c;
            }
            continue;
        }

        if (c === '"') dentroComillas = true;
        else if (c === separador) { fila.push(campo); campo = ''; }
        else if (c === '\n') { fila.push(campo); filas.push(fila); fila = []; campo = ''; }
        else if (c !== '\r') campo += c;
    }

    if (campo !== '' || fila.length) { fila.push(campo); filas.push(fila); }

    return filas.filter((f) => f.some((x) => String(x).trim() !== ''));
}

/**
 * Detecta el separador contando ocurrencias FUERA de comillas: un concepto
 * como "Cena, copas y taxi" no debe inclinar la balanza hacia la coma.
 */
export function detectarSeparador(primeraLinea) {
    const cuenta = (sep) => {
        let n = 0;
        let dentro = false;
        for (let i = 0; i < primeraLinea.length; i++) {
            const c = primeraLinea[i];
            if (c === '"') { dentro = !dentro; continue; }
            if (!dentro && c === sep) n++;
        }
        return n;
    };
    const candidatos = [[';', cuenta(';')], [',', cuenta(',')], ['\t', cuenta('\t')]];
    candidatos.sort((a, b) => b[1] - a[1]);
    return candidatos[0][1] > 0 ? candidatos[0][0] : ';';
}

export function mapearCabecera(fila) {
    const mapa = {};
    fila.forEach((celda, i) => {
        const limpio = sinTildes(celda);
        for (const [clave, alias] of Object.entries(COLUMNAS)) {
            if (mapa[clave] !== undefined) continue;
            if (alias.includes(limpio)) { mapa[clave] = i; break; }
        }
    });
    return mapa;
}

export function personaDesde(bruto, { perfiles = [], yoId = null } = {}) {
    const t = sinTildes(bruto);
    if (!t) return null;
    if (/^(yo|mi|me)$/.test(t)) return yoId;
    const p = perfiles.find((x) => sinTildes(x.display_name) === t)
           || perfiles.find((x) => t.includes(sinTildes(x.display_name)));
    return p ? p.id : null;
}

export function repartoDesde(bruto, pagadorId, { perfiles = [], yoId = null } = {}) {
    const t = sinTildes(bruto);
    if (!t) return 0.5;

    if (/(a medias|mitad|50\s*[/-]\s*50|50%)/.test(t)) return 0.5;

    const porcentajes = t.match(/^(\d{1,3})\s*[/-]\s*(\d{1,3})$/);
    if (porcentajes) {
        const n = Number(porcentajes[1]);
        if (n >= 0 && n <= 100) return n / 100;
    }

    const sueltoPct = t.match(/^(\d{1,3})\s*%$/);
    if (sueltoPct) {
        const n = Number(sueltoPct[1]);
        if (n >= 0 && n <= 100) return n / 100;
    }

    for (const p of perfiles) {
        // escaparRegex: un display_name con paréntesis rompía la importación (R13).
        if (new RegExp('solo\\s+(para\\s+|de\\s+)?' + escaparRegex(sinTildes(p.display_name))).test(t)) {
            return p.id === pagadorId ? 1 : 0;
        }
    }

    if (/solo\s+(mio|para mi|mi)/.test(t)) {
        return pagadorId === yoId ? 1 : 0;
    }

    return 0.5;
}

export function categoriaDesde(bruto) {
    const t = sinTildes(bruto);
    if (!t) return null;
    const exacta = CATEGORIES.find((c) => sinTildes(c) === t);
    if (exacta) return exacta;
    const parcial = CATEGORIES.find((c) => t.includes(sinTildes(c)));
    return parcial || null;
}

export function categoriaPorConcepto(concepto) {
    const t = sinTildes(concepto);
    if (!t) return null;

    for (const [categoria, pistas] of Object.entries(PISTAS_CATEGORIA)) {
        if (!CATEGORIES.includes(categoria)) continue;
        if (pistas.some((p) => new RegExp('\\b' + escaparRegex(sinTildes(p)) + '(s|es)?\\b').test(t))) {
            return categoria;
        }
    }
    return null;
}

export function buscarColumnaPagador(filas, mapa, contexto) {
    const ocupadas = new Set(Object.values(mapa));
    if (filas.length - 1 < 1) return undefined;

    for (let col = 0; col < filas[0].length; col++) {
        if (ocupadas.has(col)) continue;
        let aciertos = 0;
        let conValor = 0;
        for (let i = 1; i < filas.length; i++) {
            const v = (filas[i][col] ?? '').trim();
            if (!v) continue;
            conValor++;
            if (personaDesde(v, contexto)) aciertos++;
        }
        if (conValor >= 2 && aciertos / conValor >= 0.8) return col;
    }
    return undefined;
}

/**
 * Huella de 128 bits (32 caracteres hexadecimales) para dar a cada fila
 * importada un `client_id` estable.
 *
 * Sustituye al djb2 de 32 bits del monolito. Aquel producía colisiones
 * reales: 7 en un corpus de 120.000 filas, alguna entre grupos distintos.
 * Como `client_id` es único en toda la tabla, una colisión hacía que el
 * `upsert` SOBRESCRIBIERA un gasto existente —posiblemente de otro grupo—
 * en lugar de insertar el nuevo. Es decir, pérdida de un gasto sin ningún
 * aviso.
 *
 * Cuatro carriles independientes (semillas y multiplicadores primos
 * distintos, y la posición mezclada en cada paso) de 32 bits cada uno. Con
 * 128 bits, la probabilidad de colisión es despreciable a cualquier escala
 * que esta aplicación pueda alcanzar.
 */
export function huella(txt) {
    const t = String(txt);
    const semillas = [0x811c9dc5, 0x1505, 0xdeadbeef, 0x27d4eb2f];
    const primos = [16777619, 33, 31, 2654435761];
    const carriles = semillas.slice();

    for (let i = 0; i < t.length; i++) {
        const c = t.charCodeAt(i);
        for (let k = 0; k < 4; k++) {
            // Math.imul mantiene la multiplicación en 32 bits enteros:
            // sin él, JavaScript pierde precisión por encima de 2^53.
            carriles[k] = (Math.imul(carriles[k] ^ (c + k * 7 + i), primos[k]) ^
                           (carriles[k] >>> 15)) >>> 0;
        }
    }

    return carriles.map((v) => (v >>> 0).toString(16).padStart(8, '0')).join('');
}

/**
 * Analiza un CSV pegado o subido.
 *
 * @param {string} texto
 * @param {object} contexto  { perfiles, yoId, otroId, grupoId, hoy }
 */
export function analizarCSV(texto, contexto = {}) {
    const { perfiles = [], yoId = null, otroId = null, grupoId = null, hoy = hoyISO() } = contexto;
    const ctxPersona = { perfiles, yoId };

    const bruto = String(texto || '').replace(/^\uFEFF/, '').trim();
    if (!bruto) return { error: 'No hay nada que analizar.' };

    const separador = detectarSeparador(bruto.split('\n')[0]);
    const filas = trocearCSV(bruto, separador);
    if (!filas.length) return { error: 'El archivo parece vacío.' };

    const mapa = mapearCabecera(filas[0]);

    if (mapa.importe === undefined || mapa.concepto === undefined) {
        return {
            error: 'No encuentro las columnas. La primera fila debe nombrarlas, ' +
                   'al menos "Concepto" e "Importe". Exporta un CSV desde la app ' +
                   'para ver el formato exacto.',
        };
    }

    let pagadorAdivinado = false;
    if (mapa.pago === undefined) {
        const col = buscarColumnaPagador(filas, mapa, ctxPersona);
        if (col !== undefined) { mapa.pago = col; pagadorAdivinado = true; }
    }
    const sinColumnaPagador = mapa.pago === undefined;

    const gastos = [];
    const liquidaciones = [];
    const fallos = [];

    for (let i = 1; i < filas.length; i++) {
        const f = filas[i];
        const linea = i + 1;
        const dato = (clave) => (mapa[clave] === undefined ? '' : (f[mapa[clave]] ?? '').trim());

        const concepto = dato('concepto');
        const importe = aNumero(dato('importe'));

        if (!concepto && !Number.isFinite(importe)) continue;
        if (/^total/i.test(sinTildes(dato('reparto')) || sinTildes(concepto))) continue;

        if (!Number.isFinite(importe) || importe <= 0) {
            fallos.push('Línea ' + linea + ': importe ilegible (' + (dato('importe') || 'vacío') + ')');
            continue;
        }
        if (!concepto) {
            fallos.push('Línea ' + linea + ': falta el concepto');
            continue;
        }

        const fecha = fechaDesde(dato('fecha')) || hoy;
        const pagador = personaDesde(dato('pago'), ctxPersona) || yoId;
        const esLiquidacion = /liquidacion|pago|settlement/.test(sinTildes(dato('tipo')));

        // client_id determinista: reimportar el mismo archivo no duplica nada.
        const marca = 'imp:' + huella([grupoId, linea, fecha, concepto, importe, pagador].join('|'));

        if (esLiquidacion) {
            liquidaciones.push({
                group_id: grupoId,
                from_user: pagador,
                to_user: pagador === yoId ? otroId : yoId,
                amount: importe,
                note: dato('categoria') || concepto,
                settled_on: fecha,
                client_id: marca,
            });
        } else {
            gastos.push({
                group_id: grupoId,
                paid_by: pagador,
                amount: importe,
                description: concepto,
                category: categoriaDesde(dato('categoria')) || categoriaPorConcepto(concepto) || 'otros',
                payer_share: repartoDesde(dato('reparto'), pagador, ctxPersona),
                spent_on: fecha,
                client_id: marca,
            });
        }
    }

    if (!gastos.length && !liquidaciones.length) {
        return {
            error: 'No he encontrado ninguna fila aprovechable.' +
                   (fallos.length ? ' ' + fallos[0] : ''),
        };
    }

    const porPersona = perfiles.map((p) => ({
        nombre: p.display_name,
        cuantos: gastos.filter((g) => g.paid_by === p.id).length,
        suma: gastos.filter((g) => g.paid_by === p.id).reduce((t, g) => t + g.amount, 0),
    }));

    return { gastos, liquidaciones, fallos, separador, porPersona, pagadorAdivinado, sinColumnaPagador };
}

// ------------------------------------------------------------
//  Exportación
// ------------------------------------------------------------
export function campoCSV(valor) {
    const t = String(valor ?? '');
    return /[";\n]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
}

export function importeCSV(n) {
    return Number(n).toFixed(2).replace('.', ',');
}

/**
 * @param {object} datos  { gastos, liquidaciones, total }
 * @param {(id:string)=>string} nombreDe
 * @param {(id:string)=>string} otroDe
 */
export function construirCSV({ gastos = [], liquidaciones = [], total = 0 }, nombreDe, otroDe) {
    const filas = [['Fecha', 'Tipo', 'Concepto', 'Categoría', 'Pagó', 'Reparto', 'Importe']];

    const movimientos = [
        ...gastos.map((g) => ({ ...g, tipo: 'Gasto', fecha: g.spent_on })),
        ...liquidaciones.map((l) => ({ ...l, tipo: 'Liquidación', fecha: l.settled_on })),
    ].sort((a, b) => (a.fecha < b.fecha ? -1 : a.fecha > b.fecha ? 1 : 0));

    for (const m of movimientos) {
        if (m.tipo === 'Gasto') {
            const s = Number(m.payer_share);
            const reparto = s === 0.5 ? 'a medias'
                : s === 1 ? 'solo ' + nombreDe(m.paid_by)
                : s === 0 ? 'solo ' + nombreDe(otroDe(m.paid_by))
                : Math.round(s * 100) + '/' + Math.round((1 - s) * 100);

            filas.push([m.fecha, 'Gasto', m.description, m.category,
                        nombreDe(m.paid_by), reparto, importeCSV(m.amount)]);
        } else {
            filas.push([m.fecha, 'Liquidación', 'Pago a ' + nombreDe(m.to_user),
                        m.note || '', nombreDe(m.from_user), '', importeCSV(m.amount)]);
        }
    }

    filas.push([]);
    filas.push(['', '', '', '', '', 'Total gastos', importeCSV(total)]);

    return filas.map((f) => f.map(campoCSV).join(';')).join('\r\n');
}
