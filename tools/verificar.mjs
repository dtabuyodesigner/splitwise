#!/usr/bin/env node
// ============================================================
//  Comprobaciones de coherencia del proyecto
//
//  Lo que aquí se comprueba son cosas que no rompen ninguna prueba
//  unitaria pero sí rompen la app en producción:
//
//   1. Las versiones (config.js, package.json y el sw.js de CADA instancia)
//      coinciden. Si no, el service worker no invalida la caché y queda una
//      versión nueva del HTML servida junto a módulos viejos.
//   2. Todos los archivos que carga cada instancia están listados en SU
//      sw.js. Un módulo que falte deja la app rota sin conexión.
//   3. Todo lo que un sw.js promete cachear existe de verdad. `cache.addAll`
//      es todo o nada: un archivo inexistente impide instalar el SW.
//   4. Los iconos de cada manifest existen y tienen el tamaño declarado.
//   5. Ninguna instancia puede pisar el almacenamiento ni la caché de otra.
//
//  Uso:  npm run verificar
// ============================================================
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

import { REGISTRO } from '../instancias/registro.js';
import { validar } from './instancias.mjs';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const leer = (r) => readFileSync(resolve(RAIZ, r), 'utf8');

const fallos = [];
const avisos = [];
const fallo = (m) => fallos.push(m);
const aviso = (m) => avisos.push(m);

/** Resuelve una ruta relativa desde el directorio de una instancia. */
function desde(dirInstancia, relativa) {
    return posix.normalize(posix.join(dirInstancia || '.', relativa)).replace(/^\.\//, '');
}

// ------------------------------------------------------------
// 0. El registro de instancias es coherente
// ------------------------------------------------------------
for (const p of validar()) fallo('registro de instancias: ' + p);

// ------------------------------------------------------------
// 1. Versiones coherentes
// ------------------------------------------------------------
const versionConfig = leer('js/config.js').match(/VERSION_APP\s*=\s*'([^']+)'/)?.[1];
const versionPkg = JSON.parse(leer('package.json')).version;

if (!versionConfig) fallo('No encuentro VERSION_APP en js/config.js');

const mayorPkg = 'v' + String(versionPkg).split('.')[0];
if (versionConfig && mayorPkg !== versionConfig) {
    fallo(`Versión descuadrada: package.json es "${versionPkg}" (→ ${mayorPkg}) ` +
          `y js/config.js dice "${versionConfig}".`);
}

// ------------------------------------------------------------
// 2, 3 y 4. Una pasada por cada instancia
// ------------------------------------------------------------
const instancias = Object.values(REGISTRO);
let modulosVistos = new Set();

for (const inst of instancias) {
    const dir = inst.ruta;
    const etiqueta = `[${inst.id}]`;

    const rutaHTML = desde(dir, 'index.html');
    const rutaSW = desde(dir, 'sw.js');
    const rutaManifest = desde(dir, 'manifest.json');

    for (const r of [rutaHTML, rutaSW, rutaManifest]) {
        if (!existsSync(resolve(RAIZ, r))) {
            fallo(`${etiqueta} falta "${r}". Ejecuta \`npm run instancias\`.`);
        }
    }
    if (!existsSync(resolve(RAIZ, rutaSW)) || !existsSync(resolve(RAIZ, rutaHTML))) continue;

    // --- versión del service worker de esta instancia ---
    const sw = leer(rutaSW);
    const prefijoSW = sw.match(/const PREFIJO\s*=\s*'([^']*)'/)?.[1];
    const versionSW = sw.match(/const VERSION\s*=\s*PREFIJO\s*\+\s*'([^']+)'/)?.[1];

    if (!versionSW) fallo(`${etiqueta} no encuentro VERSION en ${rutaSW}`);
    else if (versionConfig && versionSW !== versionConfig) {
        fallo(`${etiqueta} versión descuadrada: js/config.js dice "${versionConfig}" ` +
              `y ${rutaSW} dice "${versionSW}". Los móviles se quedarían con la versión antigua.`);
    }
    if (prefijoSW !== inst.prefijoCache) {
        fallo(`${etiqueta} ${rutaSW} usa el prefijo de caché "${prefijoSW}" ` +
              `y el registro dice "${inst.prefijoCache}".`);
    }

    // --- lo que promete cachear, resuelto desde el directorio del SW ---
    const listadosCrudos = [...sw.matchAll(/"(\.[^"]*)"/g)].map((m) => m[1]);
    const listados = new Set(listadosCrudos.map((r) => desde(dir, r)));

    for (const crudo of listadosCrudos) {
        if (crudo.endsWith('/')) continue;          // './' es la navegación
        const r = desde(dir, crudo);
        if (!existsSync(resolve(RAIZ, r))) {
            fallo(`${etiqueta} ${rutaSW} promete cachear "${crudo}" → "${r}", que no existe. ` +
                  'cache.addAll fallaría entero.');
        }
    }

    // --- lo que carga el HTML ---
    const html = leer(rutaHTML);
    const referencias = [...html.matchAll(/(?:href|src)="((?!https?:|data:|#)[^"]+)"/g)].map((m) => m[1]);

    for (const ref of new Set(referencias)) {
        const r = desde(dir, ref);
        if (!existsSync(resolve(RAIZ, r))) fallo(`${etiqueta} ${rutaHTML} referencia "${ref}", que no existe`);
        else if (!listados.has(r)) fallo(`${etiqueta} ${rutaHTML} carga "${ref}" y ${rutaSW} no lo cachea`);
    }

    if (!html.includes(`window.__INSTANCIA__ = "${inst.id}"`)) {
        fallo(`${etiqueta} ${rutaHTML} no declara window.__INSTANCIA__ = "${inst.id}"`);
    }

    // --- módulos alcanzables desde app.js ---
    const modulos = new Set();
    (function recorrer(archivo) {
        if (modulos.has(archivo)) return;
        modulos.add(archivo);
        for (const m of leer(archivo).matchAll(/from\s+'(\.[^']+)'/g)) {
            const destino = posix.normalize(posix.join(posix.dirname(archivo), m[1]));
            if (existsSync(resolve(RAIZ, destino))) recorrer(destino);
            else fallo(`${archivo} importa "${m[1]}", que no existe`);
        }
    })('js/app.js');

    for (const m of modulos) {
        if (!listados.has(m)) fallo(`${etiqueta} el módulo "${m}" no está en la lista de ${rutaSW}`);
    }
    modulosVistos = modulos;

    // --- iconos del manifest ---
    const manifest = JSON.parse(leer(rutaManifest));
    const proposito = new Set();

    for (const icono of manifest.icons || []) {
        if (icono.src.startsWith('data:')) {
            fallo(`${etiqueta} hay un icono como data URI en ${rutaManifest}. Debe ser un PNG real.`);
            continue;
        }
        const r = desde(dir, icono.src);
        if (!existsSync(resolve(RAIZ, r))) {
            fallo(`${etiqueta} el icono "${icono.src}" del manifest no existe`);
            continue;
        }
        const buf = readFileSync(resolve(RAIZ, r));
        const esPNG = buf.subarray(1, 4).toString('ascii') === 'PNG';
        const [w, h] = icono.sizes.split('x').map(Number);
        if (!esPNG) fallo(`${etiqueta} "${icono.src}" no es un PNG válido`);
        else if (buf.readUInt32BE(16) !== w || buf.readUInt32BE(20) !== h) {
            fallo(`${etiqueta} "${icono.src}" mide ${buf.readUInt32BE(16)}x${buf.readUInt32BE(20)} ` +
                  `y el manifest declara ${icono.sizes}`);
        }
        for (const p of (icono.purpose || 'any').split(/\s+/)) proposito.add(p + ':' + icono.sizes);
    }

    for (const necesario of ['any:192x192', 'any:512x512', 'maskable:512x512']) {
        if (!proposito.has(necesario)) fallo(`${etiqueta} falta un icono ${necesario} en ${rutaManifest}`);
    }

    if (!manifest.id) {
        aviso(`${etiqueta} ${rutaManifest} no declara "id": la app instalada puede duplicarse`);
    }

    if (String(inst.supabaseUrl).includes('PENDIENTE')) {
        aviso(`${etiqueta} sin proyecto de Supabase todavía: se despliega, pero nadie puede entrar`);
    }
}

// ------------------------------------------------------------
//  Resultado
// ------------------------------------------------------------
for (const a of avisos) console.warn('  aviso  ' + a);

if (fallos.length) {
    console.error('\n' + fallos.length + ' problema(s):\n');
    for (const f of fallos) console.error('  · ' + f);
    console.error('');
    process.exit(1);
}

console.log(`Coherencia correcta · versión ${versionConfig} · ` +
            `${instancias.length} instancia(s) · ${modulosVistos.size} módulos`);
