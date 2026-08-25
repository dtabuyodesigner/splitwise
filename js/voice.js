// ============================================================
//  Dictado natural
//  `interpretarDictado` es una función pura: recibe el texto y el contexto
//  (perfiles y quién soy) y devuelve los campos que ha sabido sacar.
//  El acceso al micrófono vive en app.js.
// ============================================================
import { CATEGORIES, PISTAS_CATEGORIA } from './config.js';
import { hoyISO, ayerISO } from './fechas.js';
import { escaparRegex } from './csv.js';

function quitarFragmento(texto, fragmento) {
    if (!fragmento) return texto;
    const i = texto.toLowerCase().indexOf(String(fragmento).toLowerCase());
    if (i === -1) return texto;
    return texto.slice(0, i) + ' ' + texto.slice(i + fragmento.length);
}

const FIN = '(?![a-záéíóúüñ])';
const PRON = '(?:(?:lo|la|los|las|le|se)\\s+)?';
const AUX = '(?:(?:ha|han|he|hemos|habia|había)\\s+)?';
const VERBO = '(?:pag[oóa]|pagu[eé]|pagado|pagaron|invit[oóaé]|invito|puso|puse|pusimos|pone|pongo|puesto)';

/**
 * @param {string} bruto
 * @param {object} contexto  { perfiles, yoId, ahora }
 * @returns {{importe?:number, concepto?:string, categoria?:string,
 *            fecha?:string, pagador?:string, asume:string}|null}
 */
export function interpretarDictado(bruto, contexto = {}) {
    const { perfiles = [], yoId = null, ahora = new Date() } = contexto;

    const original = String(bruto || '').trim();
    if (!original) return null;

    const r = { asume: 'ambos' };
    let resto = original;
    const bajo = original.toLowerCase();

    // --- Importe ---
    const patronesImporte = [
        /(\d+)\s*(?:euros?|€)\s*(?:con|y)\s*(\d{1,2})\b/,
        /(\d+)\s*(?:con|y)\s*(\d{1,2})\s*(?:c[eé]ntimos?)?\b/,
        /(\d+)\s*[.,]\s*(\d{1,2})\b/,
        /^(\d+)\s+(\d{2})\b/,
        /(\d+)\s*(?:euros?|€)/,
        /\b(\d+)\b/,
    ];

    for (const p of patronesImporte) {
        const m = bajo.match(p);
        if (!m) continue;
        const enteros = Number(m[1]);
        const centimos = m[2] ? Number(String(m[2]).padEnd(2, '0')) : 0;
        r.importe = Math.round((enteros + centimos / 100) * 100) / 100;
        resto = quitarFragmento(resto, m[0]);
        break;
    }

    resto = resto.replace(/\b(euros?)\b/gi, ' ').replace(/€/g, ' ');

    // --- Fecha ---
    if (/\bayer\b/i.test(resto)) {
        r.fecha = ayerISO(ahora);
        resto = resto.replace(/\bayer\b/i, ' ');
    } else if (/\bhoy\b/i.test(resto)) {
        r.fecha = hoyISO(ahora);
        resto = resto.replace(/\bhoy\b/i, ' ');
    }

    // --- Quién pagó ---
    const yoPague = resto.match(new RegExp(
        '\\b' + PRON + AUX + '(?:pagu[eé]|puse|invit[eé]|pagado|puesto)(?:\\s+yo)?' + FIN, 'i'
    )) || resto.match(/\b(pago yo|pongo yo|invito yo|corre de mi cuenta)\b/i);

    const nombreJunto = perfiles.some((p) => {
        const n = escaparRegex(p.display_name);
        return new RegExp('\\b' + VERBO + '\\s+' + n + FIN, 'i').test(resto)
            || new RegExp('\\b' + n + '\\s+' + PRON + AUX + VERBO + FIN, 'i').test(resto);
    });

    if (yoPague && !nombreJunto) {
        r.pagador = yoId;
        resto = quitarFragmento(resto, yoPague[0]);
        resto = resto.replace(/\byo\b/gi, ' ');
    } else {
        let encontrado = null;

        for (const p of perfiles) {
            const n = escaparRegex(p.display_name);
            const detras = resto.match(new RegExp('\\b' + PRON + AUX + VERBO + '\\s+' + n + FIN, 'i'));
            const delante = resto.match(new RegExp('\\b' + n + '\\s+' + PRON + AUX + VERBO + FIN, 'i'));
            const rodeo = resto.match(new RegExp('\\b(?:a cargo de|de parte de|por parte de|cuenta de)\\s+' + n + FIN, 'i'));

            encontrado = detras || delante || rodeo;
            if (encontrado) {
                r.pagador = p.id;
                resto = quitarFragmento(resto, encontrado[0]);
                break;
            }
        }

        if (!encontrado) {
            for (const p of perfiles) {
                const n = escaparRegex(p.display_name);
                const alFinal = resto.match(new RegExp('\\s' + n + '\\s*$', 'i'));
                if (alFinal) {
                    r.pagador = p.id;
                    resto = resto.replace(new RegExp('\\s' + n + '\\s*$', 'i'), ' ');
                    break;
                }
            }
        }
    }

    // --- Reparto ---
    if (/\b(a medias|mitad y mitad|entre los dos|entre las dos|al 50)\b/i.test(resto)) {
        r.asume = 'ambos';
        resto = resto.replace(/\b(a medias|mitad y mitad|entre los dos|entre las dos|al 50)\b/i, ' ');
    } else {
        // El \b final del monolito no cerraba después de una vocal acentuada:
        // en JavaScript "í" no es un carácter de palabra, así que no hay
        // frontera entre "mí" y el espacio y "solo para mí" nunca casaba.
        // FIN hace el mismo trabajo y sí funciona con tildes.
        const soloMio = resto.match(new RegExp(
            '\\b(solo\\s+(para\\s+)?m[ií]o?|s[oó]lo\\s+(para\\s+)?m[ií]o?|' +
            'es\\s+m[ií]o|para\\s+m[ií]\\s+solo)' + FIN, 'i'));
        if (soloMio) {
            r.asume = yoId;
            resto = quitarFragmento(resto, soloMio[0]);
        } else {
            for (const p of perfiles) {
                const n = escaparRegex(p.display_name);
                const m = resto.match(new RegExp('\\b(s[oó]lo\\s+(para\\s+|de\\s+)?|es de\\s+|para\\s+)' + n + '\\b', 'i'));
                if (m) {
                    r.asume = p.id;
                    resto = quitarFragmento(resto, m[0]);
                    break;
                }
            }
        }
    }

    resto = resto.replace(new RegExp('\\b' + PRON + AUX + VERBO + FIN, 'gi'), ' ');
    for (const p of perfiles) {
        resto = resto.replace(new RegExp('\\s' + escaparRegex(p.display_name) + '\\s*$', 'i'), ' ');
    }
    resto = resto.replace(/\byo\b/gi, ' ');

    // --- Categoría ---
    const limpioBajo = resto.toLowerCase();
    for (const [categoria, pistas] of Object.entries(PISTAS_CATEGORIA)) {
        if (!CATEGORIES.includes(categoria)) continue;
        if (pistas.some((pista) => new RegExp('\\b' + escaparRegex(pista) + '(s|es)?' + FIN, 'i').test(limpioBajo))) {
            r.categoria = categoria;
            break;
        }
    }
    if (!r.categoria) {
        const directa = CATEGORIES.find((c) =>
            new RegExp('\\b' + escaparRegex(c) + FIN, 'i').test(limpioBajo));
        if (directa) r.categoria = directa;
    }

    // --- Concepto ---
    let concepto = resto.replace(/\s+/g, ' ').trim();
    const RELLENO = 'lo|la|los|las|le|se|que|y|de|del|en|por|para|el|un|una|ha|han|he|hemos|yo|con|a|al|eso|esto';
    const porDelante = new RegExp('^(?:' + RELLENO + ')\\b[\\s,.;:·-]*', 'i');
    const porDetras  = new RegExp('[\\s,.;:·-]*\\b(?:' + RELLENO + ')$', 'i');

    let anterior;
    do {
        anterior = concepto;
        concepto = concepto
            .replace(/^[\s,.;:·-]+|[\s,.;:·-]+$/g, '')
            .replace(porDelante, '')
            .replace(porDetras, '')
            .trim();
    } while (concepto !== anterior && concepto);

    if (concepto) {
        r.concepto = concepto.charAt(0).toUpperCase() + concepto.slice(1);
    } else if (r.categoria) {
        r.concepto = r.categoria.charAt(0).toUpperCase() + r.categoria.slice(1);
    }

    return r;
}
