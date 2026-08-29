#!/usr/bin/env node
// ============================================================
//  Servidor estático mínimo para desarrollo.
//
//  La app usa módulos ES nativos, así que NO funciona abriendo el archivo
//  con file://: hace falta servirla por HTTP.
//
//  Uso:  npm run servir   →  http://localhost:8080
// ============================================================
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PUERTO = Number(process.env.PUERTO || 8080);

const TIPOS = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.png': 'image/png',
    '.svg': 'image/svg+xml',
    '.webmanifest': 'application/manifest+json',
};

createServer(async (peticion, respuesta) => {
    const url = new URL(peticion.url, 'http://localhost');
    let ruta = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, '');
    if (ruta === '/' || ruta === '') ruta = '/index.html';

    const archivo = join(RAIZ, ruta);
    if (!archivo.startsWith(RAIZ)) {
        respuesta.writeHead(403).end('Fuera de la raíz');
        return;
    }

    try {
        let archivoFinal = archivo;
        const info = await stat(archivo);

        // Un directorio se sirve con su index.html, que es lo que hace
        // GitHub Pages. Sin esto, `/alba/` daba 404 en local y solo en
        // local: el fallo no aparecía hasta desplegar.
        if (info.isDirectory()) {
            archivoFinal = join(archivo, 'index.html');
            const indice = await stat(archivoFinal);
            if (!indice.isFile()) throw new Error('sin index.html');

            // Redirección a la barra final: si no, las rutas relativas de
            // dentro del HTML se resuelven un nivel más arriba del que toca.
            if (!url.pathname.endsWith('/')) {
                respuesta.writeHead(301, { Location: url.pathname + '/' }).end();
                return;
            }
        }

        const cuerpo = await readFile(archivoFinal);
        respuesta.writeHead(200, {
            'Content-Type': TIPOS[extname(archivoFinal)] || 'application/octet-stream',
            // Sin caché: en desarrollo interesa ver el último cambio siempre.
            'Cache-Control': 'no-store',
        });
        respuesta.end(cuerpo);
    } catch {
        respuesta.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        respuesta.end('No encontrado: ' + ruta);
    }
}).listen(PUERTO, () => {
    console.log('Gastos compartidos en http://localhost:' + PUERTO);
});
