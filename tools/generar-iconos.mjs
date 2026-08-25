#!/usr/bin/env node
// ============================================================
//  Generador de iconos PNG
//
//  Sustituye a los data URI del manifest (riesgo R14). No usa ninguna
//  dependencia: dibuja los píxeles y los codifica en PNG con `zlib`, que
//  ya viene con Node. Es reproducible: el mismo código da el mismo archivo.
//
//  Uso:  npm run iconos
// ============================================================
import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');

// Paleta de la app (styles.css)
const FONDO     = [0x14, 0x20, 0x1F];
const LAUREL    = [0x7F, 0xC8, 0xB4];
const BUGANVILLA= [0xD9, 0x8C, 0xA8];

// ------------------------------------------------------------
//  Codificador PNG mínimo (RGB, 8 bits, sin entrelazado)
// ------------------------------------------------------------
const TABLA_CRC = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        t[n] = c >>> 0;
    }
    return t;
})();

function crc32(buf) {
    let c = 0xffffffff;
    for (let i = 0; i < buf.length; i++) c = TABLA_CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}

function trozo(tipo, datos) {
    const largo = Buffer.alloc(4);
    largo.writeUInt32BE(datos.length, 0);
    const cuerpo = Buffer.concat([Buffer.from(tipo, 'ascii'), datos]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(cuerpo), 0);
    return Buffer.concat([largo, cuerpo, crc]);
}

function codificarPNG(ancho, alto, pixeles) {
    const cabecera = Buffer.alloc(13);
    cabecera.writeUInt32BE(ancho, 0);
    cabecera.writeUInt32BE(alto, 4);
    cabecera[8] = 8;    // bits por canal
    cabecera[9] = 2;    // color: RGB
    cabecera[10] = 0;   // compresión: deflate
    cabecera[11] = 0;   // filtro: adaptativo
    cabecera[12] = 0;   // sin entrelazado

    // Cada fila lleva delante su byte de filtro (0 = ninguno).
    const bruto = Buffer.alloc(alto * (1 + ancho * 3));
    for (let y = 0; y < alto; y++) {
        const destino = y * (1 + ancho * 3);
        bruto[destino] = 0;
        pixeles.copy(bruto, destino + 1, y * ancho * 3, (y + 1) * ancho * 3);
    }

    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        trozo('IHDR', cabecera),
        trozo('IDAT', deflateSync(bruto, { level: 9 })),
        trozo('IEND', Buffer.alloc(0)),
    ]);
}

// ------------------------------------------------------------
//  Dibujo
// ------------------------------------------------------------
const mezclar = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));

/**
 * Moneda partida en dos mitades: el gasto que se reparte.
 * @param {number} tam    lado en píxeles
 * @param {number} radio  radio de la moneda, en fracción del lado
 * @param {boolean} conAro  dibuja el aro exterior (versión "any")
 */
function dibujar(tam, radio, conAro) {
    const px = Buffer.alloc(tam * tam * 3);
    const centro = (tam - 1) / 2;
    const r = tam * radio;
    const rAro = r * 1.16;
    const grosorHueco = Math.max(1.5, tam * 0.018);
    const suave = Math.max(1, tam / 256);   // antialiasing de 1 px lógico

    const poner = (x, y, color) => {
        const i = (y * tam + x) * 3;
        px[i] = color[0]; px[i + 1] = color[1]; px[i + 2] = color[2];
    };

    for (let y = 0; y < tam; y++) {
        for (let x = 0; x < tam; x++) {
            const dx = x - centro;
            const dy = y - centro;
            const d = Math.hypot(dx, dy);

            let color = FONDO;

            if (conAro && d > r && d < rAro) {
                // Aro tenue alrededor de la moneda.
                const t = 1 - Math.min(1, Math.abs(d - (r + rAro) / 2) / ((rAro - r) / 2));
                color = mezclar(FONDO, LAUREL, 0.35 * t);
            }

            if (d <= r + suave) {
                const dentro = Math.min(1, Math.max(0, (r + suave - d) / (2 * suave)));
                const mitad = dx < 0 ? LAUREL : BUGANVILLA;
                color = mezclar(color, mitad, dentro);

                // Hueco vertical que separa las dos mitades.
                const enHueco = Math.min(1, Math.max(0, (grosorHueco - Math.abs(dx)) / grosorHueco));
                if (enHueco > 0) color = mezclar(color, FONDO, enHueco * dentro);
            }

            poner(x, y, color);
        }
    }

    return codificarPNG(tam, tam, px);
}

// ------------------------------------------------------------
mkdirSync(resolve(RAIZ, 'icons'), { recursive: true });

const salidas = [
    // `any`: la moneda ocupa casi todo el lienzo.
    ['icons/icon-192.png', dibujar(192, 0.38, true)],
    ['icons/icon-512.png', dibujar(512, 0.38, true)],
    ['icons/apple-touch-180.png', dibujar(180, 0.38, true)],
    // `maskable`: el contenido cabe en el 80 % central, que es la zona que
    // ningún recorte de Android puede comerse.
    ['icons/maskable-192.png', dibujar(192, 0.28, false)],
    ['icons/maskable-512.png', dibujar(512, 0.28, false)],
    // Favicon pequeño.
    ['icons/favicon-32.png', dibujar(32, 0.40, false)],
];

for (const [ruta, datos] of salidas) {
    writeFileSync(resolve(RAIZ, ruta), datos);
    console.log(ruta.padEnd(30), (datos.length / 1024).toFixed(1) + ' KB');
}
