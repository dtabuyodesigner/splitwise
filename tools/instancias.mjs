#!/usr/bin/env node
// ============================================================
//  Generador de instancias
//
//  Lee `instancias/registro.js` y escribe, para cada instancia, los TRES
//  únicos archivos que no se pueden compartir entre despliegues:
//
//      <ruta>/index.html      · lleva window.__INSTANCIA__ y los textos
//      <ruta>/manifest.json   · id, scope y start_url propios → icono propio
//      <ruta>/sw.js           · caché propia y ámbito propio
//
//  Todo lo demás (styles.css, js/, icons/) es compartido y se referencia
//  con rutas relativas hacia la raíz. No se duplica una sola línea de
//  aplicación.
//
//  Uso:
//      npm run instancias            escribe los archivos
//      npm run instancias -- --check no escribe; falla si hay diferencias
//
//  El modo --check es lo que ejecuta CI: garantiza que nadie ha editado a
//  mano un archivo generado.
// ============================================================
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { INSTANCIAS, REGISTRO } from '../instancias/registro.js';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const COMPROBAR = process.argv.includes('--check');

const leer = (r) => readFileSync(resolve(RAIZ, r), 'utf8');

const VERSION_APP = leer('js/config.js').match(/VERSION_APP\s*=\s*'([^']+)'/)?.[1];
if (!VERSION_APP) {
    console.error('No encuentro VERSION_APP en js/config.js');
    process.exit(1);
}

// ------------------------------------------------------------
//  Qué archivos comparte la aplicación
//  Se descubren, no se listan: así añadir un módulo a js/ no obliga a
//  acordarse de tocar el service worker de cada instancia.
// ------------------------------------------------------------
function compartidos() {
    const js = readdirSync(resolve(RAIZ, 'js')).filter((f) => f.endsWith('.js')).sort();
    const iconos = readdirSync(resolve(RAIZ, 'icons')).filter((f) => f.endsWith('.png')).sort();
    return [
        'styles.css',
        ...js.map((f) => 'js/' + f),
        'instancias/registro.js',
        ...iconos.map((f) => 'icons/' + f),
    ];
}

// ------------------------------------------------------------
//  Validación del registro
//  Fallar aquí es barato. Fallar en producción, con dos instancias
//  pisándose el localStorage, no lo es.
// ------------------------------------------------------------
function validar() {
    const problemas = [];
    const ids = new Set();
    const rutas = new Set();

    for (const bruto of INSTANCIAS) {
        const i = REGISTRO[bruto.id];

        if (!/^[a-z0-9-]+$/.test(i.id)) {
            problemas.push(`id "${i.id}": solo minúsculas, dígitos y guiones.`);
        }
        if (ids.has(i.id)) problemas.push(`id "${i.id}" repetido.`);
        ids.add(i.id);

        if (i.ruta && !/^[a-z0-9-]+$/.test(i.ruta)) {
            problemas.push(`ruta "${i.ruta}" de ${i.id}: un solo segmento, sin barras.`);
        }
        if (rutas.has(i.ruta)) {
            problemas.push(`la ruta "${i.ruta || '(raíz)'}" está usada por dos instancias.`);
        }
        rutas.add(i.ruta);
    }

    // Invariante crítico: ningún prefijo puede ser prefijo de otro. Si lo
    // fuera, `purgarOtrosUsuarios` borraría datos de la instancia vecina y
    // `activate` del service worker le borraría la caché.
    for (const a of Object.values(REGISTRO)) {
        for (const b of Object.values(REGISTRO)) {
            if (a.id === b.id) continue;
            if (b.prefijoAlmacen.startsWith(a.prefijoAlmacen + '.')) {
                problemas.push(
                    `el prefijo de almacenamiento de "${a.id}" (${a.prefijoAlmacen}) contiene ` +
                    `al de "${b.id}" (${b.prefijoAlmacen}): se borrarían datos entre instancias.`);
            }
            if (a.claveCorreo === b.claveCorreo) {
                problemas.push(`"${a.id}" y "${b.id}" comparten claveCorreo.`);
            }
            if (a.claveSesion === b.claveSesion) {
                problemas.push(`"${a.id}" y "${b.id}" comparten claveSesion.`);
            }
            const patronDeA = new RegExp('^' + a.prefijoCache.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&') + 'v\\d+$');
            if (patronDeA.test(b.prefijoCache + 'v1')) {
                problemas.push(
                    `la caché de "${a.id}" (${a.prefijoCache}) también captura la de "${b.id}": ` +
                    'una instancia borraría la caché de la otra al desplegar.');
            }
        }
    }

    // Dos instancias distintas nunca deben apuntar al mismo proyecto: sería
    // exactamente lo contrario de lo que se pretende.
    const porProyecto = new Map();
    for (const i of Object.values(REGISTRO)) {
        if (String(i.supabaseUrl).includes('PENDIENTE')) continue;
        const previa = porProyecto.get(i.supabaseUrl);
        if (previa) {
            problemas.push(
                `"${previa}" y "${i.id}" apuntan al mismo proyecto de Supabase ` +
                `(${i.supabaseUrl}). Las instancias no comparten datos.`);
        }
        porProyecto.set(i.supabaseUrl, i.id);
    }

    return problemas;
}

// ------------------------------------------------------------
//  Render
// ------------------------------------------------------------
const escaparHTML = (s) => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** El nombre partido en dos líneas para la pantalla de acceso. */
function marcaHTML(nombre) {
    const palabras = nombre.trim().split(/\s+/);
    if (palabras.length < 2) return escaparHTML(nombre);
    const corte = Math.ceil(palabras.length / 2);
    return escaparHTML(palabras.slice(0, corte).join(' ')) + '<br>'
         + escaparHTML(palabras.slice(corte).join(' '));
}

function render(plantilla, sustituciones) {
    let salida = plantilla;
    for (const [clave, valor] of Object.entries(sustituciones)) {
        salida = salida.split('{{' + clave + '}}').join(valor);
    }
    const huerfano = salida.match(/\{\{([A-Z_]+)\}\}/);
    if (huerfano) throw new Error(`Marcador sin sustituir: ${huerfano[0]}`);
    return salida;
}

function archivosDeInstancia(inst, todosCompartidos) {
    const profundidad = inst.ruta ? inst.ruta.split('/').length : 0;
    const base = '../'.repeat(profundidad);
    return {
        base,
        // Lo propio con './', lo compartido subiendo hasta la raíz.
        lista: [
            './',
            './index.html',
            './manifest.json',
            ...todosCompartidos.map((f) => (base ? base + f : './' + f)),
        ],
    };
}

function generar() {
    const plantillas = {
        html: leer('tools/plantillas/index.html'),
        manifest: leer('tools/plantillas/manifest.json'),
        sw: leer('tools/plantillas/sw.js'),
    };
    const comunes = compartidos();
    const salida = new Map();

    for (const inst of Object.values(REGISTRO)) {
        const { base, lista } = archivosDeInstancia(inst, comunes);
        const ajenas = INSTANCIAS
            .filter((o) => o.id !== inst.id && o.ruta && !inst.ruta)
            .map((o) => o.ruta);

        const comunesSust = {
            ID: inst.id,
            BASE: base,
            NOMBRE: escaparHTML(inst.nombre),
            NOMBRE_CORTO: escaparHTML(inst.nombreCorto),
            LEMA: escaparHTML(inst.lema),
            LEMA_MINUS: escaparHTML(inst.lema.charAt(0).toLowerCase() + inst.lema.slice(1)),
            MARCA_HTML: marcaHTML(inst.nombre),
        };

        const dir = inst.ruta ? inst.ruta + '/' : '';

        salida.set(dir + 'index.html', render(plantillas.html, comunesSust));

        salida.set(dir + 'manifest.json', render(plantillas.manifest, {
            ...comunesSust,
            NOMBRE: JSON.stringify(inst.nombre).slice(1, -1),
            NOMBRE_CORTO: JSON.stringify(inst.nombreCorto).slice(1, -1),
            LEMA: JSON.stringify(inst.lema).slice(1, -1),
            // `id` distingue la app instalada. Sin uno propio por instancia,
            // iOS y Android las tratan como la misma y solo aparece un icono.
            ID_MANIFEST: './',
        }));

        salida.set(dir + 'sw.js', render(plantillas.sw, {
            ID: inst.id,
            PREFIJO_CACHE: inst.prefijoCache,
            VERSION_APP,
            RUTAS_AJENAS: JSON.stringify(ajenas),
            ARCHIVOS: JSON.stringify(lista, null, 4).replace(/\n/g, '\n'),
        }));
    }

    return salida;
}

// ------------------------------------------------------------
//  Ejecución
//
//  Solo cuando se invoca directamente. `tools/verificar.mjs` y las pruebas
//  importan `validar` y `generar` sin que se escriba nada.
// ------------------------------------------------------------
export { validar, generar, archivosDeInstancia, marcaHTML, compartidos };

const ejecutadoDirectamente =
    process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (!ejecutadoDirectamente) {
    // Nada más que hacer: este archivo se está usando como biblioteca.
} else {

const problemas = validar();
if (problemas.length) {
    console.error(`\nRegistro de instancias inválido (${problemas.length}):\n`);
    for (const p of problemas) console.error('  · ' + p);
    console.error('');
    process.exit(1);
}

const archivos = generar();
const diferentes = [];

for (const [ruta, contenido] of archivos) {
    const destino = resolve(RAIZ, ruta);
    const actual = existsSync(destino) ? readFileSync(destino, 'utf8') : null;
    if (actual === contenido) continue;

    diferentes.push(ruta);
    if (!COMPROBAR) {
        mkdirSync(dirname(destino), { recursive: true });
        writeFileSync(destino, contenido);
    }
}

if (COMPROBAR) {
    if (diferentes.length) {
        console.error('\nHay archivos generados que no coinciden con las plantillas:\n');
        for (const r of diferentes) console.error('  · ' + r);
        console.error('\nEjecuta `npm run instancias` y vuelve a hacer commit.\n');
        process.exit(1);
    }
    console.log(`Instancias al día · ${archivos.size} archivos · ${Object.keys(REGISTRO).length} instancias`);
} else {
    const nombres = Object.values(REGISTRO)
        .map((i) => `${i.id}${i.ruta ? ' → /' + i.ruta + '/' : ' → /'}`)
        .join(' · ');
    console.log(
        diferentes.length
            ? `Generados ${diferentes.length} archivo(s):\n  ${diferentes.join('\n  ')}\n\n${nombres}`
            : `Nada que hacer, ya estaba al día.\n\n${nombres}`
    );
}

// Recordatorio de instancias a medio configurar.
for (const i of Object.values(REGISTRO)) {
    if (String(i.supabaseUrl).includes('PENDIENTE') || String(i.supabaseAnonKey).includes('PENDIENTE')) {
        console.warn(`\n  aviso  la instancia "${i.id}" aún no tiene proyecto de Supabase. ` +
                     'Se despliega, pero no podrá entrar nadie. Ver docs/MULTI-INSTANCIA.md §4.');
    }
}

}  // fin de `ejecutadoDirectamente`
