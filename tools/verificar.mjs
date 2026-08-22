#!/usr/bin/env node
// ============================================================
//  Comprobaciones de coherencia del proyecto
//
//  Lo que aquí se comprueba son cosas que no rompen ninguna prueba
//  unitaria pero sí rompen la app en producción:
//
//   1. Las tres versiones (config.js, sw.js, package.json) coinciden.
//      Si no, el service worker no invalida la caché y queda una versión
//      nueva del HTML servida junto a módulos viejos.
//   2. Todos los archivos que la app carga están listados en sw.js.
//      Un módulo que falte deja la app rota sin conexión.
//   3. Todo lo que sw.js promete cachear existe de verdad. `cache.addAll`
//      es todo o nada: un archivo inexistente impide instalar el SW.
//   4. Los iconos del manifest existen y tienen el tamaño declarado.
//
//  Uso:  npm run verificar
// ============================================================
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const leer = (r) => readFileSync(resolve(RAIZ, r), 'utf8');

const fallos = [];
const avisos = [];
const fallo = (m) => fallos.push(m);
const aviso = (m) => avisos.push(m);

// ------------------------------------------------------------
// 1. Versiones coherentes
// ------------------------------------------------------------
const versionConfig = leer('js/config.js').match(/VERSION_APP\s*=\s*'([^']+)'/)?.[1];
const versionSW = leer('sw.js').match(/const VERSION\s*=\s*'gastos-([^']+)'/)?.[1];
const versionPkg = JSON.parse(leer('package.json')).version;

if (!versionConfig) fallo('No encuentro VERSION_APP en js/config.js');
if (!versionSW) fallo('No encuentro VERSION en sw.js');

if (versionConfig && versionSW && versionConfig !== versionSW) {
    fallo(`Versión descuadrada: js/config.js dice "${versionConfig}" y sw.js dice "${versionSW}". ` +
          'Si no coinciden, los móviles se quedan con la versión antigua.');
}

const mayorPkg = 'v' + String(versionPkg).split('.')[0];
if (versionConfig && mayorPkg !== versionConfig) {
    fallo(`Versión descuadrada: package.json es "${versionPkg}" (→ ${mayorPkg}) ` +
          `y js/config.js dice "${versionConfig}".`);
}

// ------------------------------------------------------------
// 2 y 3. Lo que carga la app y lo que promete el service worker
// ------------------------------------------------------------
const sw = leer('sw.js');
const listados = [...sw.matchAll(/'\.\/([^']*)'/g)].map((m) => m[1]).filter(Boolean);

const html = leer('index.html');
const referenciasHTML = [
    ...[...html.matchAll(/(?:href|src)="((?!https?:|data:|#)[^"]+)"/g)].map((m) => m[1]),
];

for (const ruta of new Set(referenciasHTML)) {
    if (!existsSync(resolve(RAIZ, ruta))) fallo(`index.html referencia "${ruta}", que no existe`);
    if (!listados.includes(ruta)) fallo(`index.html carga "${ruta}" y sw.js no lo cachea`);
}

// Módulos que se importan entre sí.
const modulos = new Set();
function recorrer(archivo) {
    if (modulos.has(archivo)) return;
    modulos.add(archivo);
    const fuente = leer(archivo);
    for (const m of fuente.matchAll(/from\s+'(\.[^']+)'/g)) {
        const destino = resolve(dirname(resolve(RAIZ, archivo)), m[1]).slice(RAIZ.length + 1);
        if (existsSync(resolve(RAIZ, destino))) recorrer(destino);
        else fallo(`${archivo} importa "${m[1]}", que no existe`);
    }
}
recorrer('js/app.js');

for (const m of modulos) {
    if (!listados.includes(m)) fallo(`El módulo "${m}" no está en la lista de sw.js`);
}

for (const ruta of listados) {
    if (ruta === '') continue;
    if (!existsSync(resolve(RAIZ, ruta))) {
        fallo(`sw.js promete cachear "${ruta}", que no existe. cache.addAll fallaría entero.`);
    }
}

// ------------------------------------------------------------
// 4. Iconos del manifest
// ------------------------------------------------------------
const manifest = JSON.parse(leer('manifest.json'));

function tamañoPNG(ruta) {
    const buf = readFileSync(resolve(RAIZ, ruta));
    if (buf.subarray(1, 4).toString('ascii') !== 'PNG') return null;
    return { ancho: buf.readUInt32BE(16), alto: buf.readUInt32BE(20) };
}

const proposito = new Set();
for (const icono of manifest.icons || []) {
    if (icono.src.startsWith('data:')) {
        fallo('Hay un icono como data URI en manifest.json. Debe ser un archivo PNG real.');
        continue;
    }
    if (!existsSync(resolve(RAIZ, icono.src))) {
        fallo(`El icono "${icono.src}" del manifest no existe`);
        continue;
    }
    const t = tamañoPNG(icono.src);
    const [w, h] = icono.sizes.split('x').map(Number);
    if (!t) fallo(`"${icono.src}" no es un PNG válido`);
    else if (t.ancho !== w || t.alto !== h) {
        fallo(`"${icono.src}" mide ${t.ancho}x${t.alto} y el manifest declara ${icono.sizes}`);
    }
    for (const p of (icono.purpose || 'any').split(/\s+/)) proposito.add(p + ':' + icono.sizes);
}

for (const necesario of ['any:192x192', 'any:512x512', 'maskable:512x512']) {
    if (!proposito.has(necesario)) fallo(`Falta un icono ${necesario} en manifest.json`);
}

if (!manifest.id) aviso('manifest.json no declara "id": la app instalada puede duplicarse al cambiar start_url');

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
            `${modulos.size} módulos · ${(manifest.icons || []).length} iconos`);
