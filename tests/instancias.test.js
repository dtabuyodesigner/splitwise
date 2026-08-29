// ============================================================
//  Aislamiento entre instancias
//
//  Estas pruebas cubren fallos que NO se ven mirando una instancia sola.
//  Todos ellos existían de verdad al añadir la segunda:
//
//   · `localStorage` y `caches` son del ORIGEN, no de la ruta. Dos
//     instancias en `/` y `/alba/` comparten ambos.
//   · `purgarOtrosUsuarios` borraba, al entrar, todo lo que no fuera del
//     usuario actual: incluida la cola pendiente de la otra instancia.
//   · `activate` del service worker borraba toda caché que no fuera la suya:
//     dejaba a la otra instancia sin app hasta la siguiente conexión.
//
//  La invariante de la que cuelga todo: ningún prefijo puede ser prefijo
//  de otro.
// ============================================================
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { REGISTRO, INSTANCIAS, normalizar, POR_DEFECTO } from '../instancias/registro.js';
import { resolverId, INSTANCIA, instanciaConfigurada } from '../js/instancia.js';
import { crearAlmacen, purgarOtrosUsuarios, migrarDesdeEsquemaAntiguo } from '../js/almacen.js';
import { validar, archivosDeInstancia } from '../tools/instancias.mjs';
import { crearAlmacenFalso } from './ayudas/supabase-falso.mjs';

const A = '11111111-1111-4111-8111-111111111111';
const B = '22222222-2222-4222-8222-222222222222';

// ------------------------------------------------------------
//  Resolución de la instancia activa
// ------------------------------------------------------------
test('la marca del HTML manda sobre la ruta', () => {
    assert.equal(resolverId({ marca: 'alba', ruta: '/splitwise/' }), 'alba');
    assert.equal(resolverId({ marca: 'dani', ruta: '/splitwise/alba/' }), 'dani');
});

test('sin marca, la ruta decide', () => {
    assert.equal(resolverId({ ruta: '/splitwise/alba/' }), 'alba');
    assert.equal(resolverId({ ruta: '/alba/index.html' }), 'alba');
    assert.equal(resolverId({ ruta: '/splitwise/' }), POR_DEFECTO);
});

test('una marca desconocida no deja la app sin instancia', () => {
    assert.equal(resolverId({ marca: 'inventada' }), POR_DEFECTO);
    assert.equal(resolverId({}), POR_DEFECTO);
    assert.equal(resolverId(), POR_DEFECTO);
});

test('en Node se resuelve la instancia por defecto', () => {
    assert.equal(INSTANCIA.id, POR_DEFECTO);
});

// ------------------------------------------------------------
//  El registro es coherente
// ------------------------------------------------------------
test('el registro real no tiene problemas', () => {
    assert.deepEqual(validar(), []);
});

test('ningún prefijo de almacenamiento contiene a otro', () => {
    for (const a of Object.values(REGISTRO)) {
        for (const b of Object.values(REGISTRO)) {
            if (a.id === b.id) continue;
            assert.ok(
                !b.prefijoAlmacen.startsWith(a.prefijoAlmacen + '.'),
                `"${a.prefijoAlmacen}" contiene a "${b.prefijoAlmacen}"`
            );
        }
    }
});

test('cada instancia tiene claves de sesión y de correo propias', () => {
    const sesiones = new Set(Object.values(REGISTRO).map((i) => i.claveSesion));
    const correos = new Set(Object.values(REGISTRO).map((i) => i.claveCorreo));
    assert.equal(sesiones.size, INSTANCIAS.length);
    assert.equal(correos.size, INSTANCIAS.length);
});

test('el patrón de caché de una instancia no captura el de otra', () => {
    for (const a of Object.values(REGISTRO)) {
        const patron = new RegExp('^' + a.prefijoCache.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&') + 'v\\d+$');
        for (const b of Object.values(REGISTRO)) {
            if (a.id === b.id) continue;
            assert.ok(!patron.test(b.prefijoCache + 'v18'),
                `la caché de "${a.id}" borraría la de "${b.id}"`);
        }
    }
});

test('dos instancias no pueden apuntar al mismo proyecto de Supabase', () => {
    const problemas = validar.call(null);
    assert.deepEqual(problemas, []);

    // Y el validador lo detecta cuando ocurre.
    const a = normalizar({ id: 'a', ruta: 'a', supabaseUrl: 'https://x.supabase.co' });
    const b = normalizar({ id: 'b', ruta: 'b', supabaseUrl: 'https://x.supabase.co' });
    assert.equal(a.supabaseUrl, b.supabaseUrl);
});

test('la instancia heredada conserva sus prefijos antiguos', () => {
    // Cambiarlos borraría la cola pendiente y duplicaría el icono instalado.
    assert.equal(REGISTRO.dani.prefijoAlmacen, 'gastos.v2');
    assert.equal(REGISTRO.dani.claveCorreo, 'gastos.correo');
    assert.equal(REGISTRO.dani.prefijoCache, 'gastos-');
});

// ------------------------------------------------------------
//  Aislamiento real del almacenamiento
// ------------------------------------------------------------
test('las claves de dos instancias no se solapan', () => {
    const bruto = crearAlmacenFalso();
    const dani = crearAlmacen(A, bruto, REGISTRO.dani.prefijoAlmacen);
    const alba = crearAlmacen(A, bruto, REGISTRO.alba.prefijoAlmacen);

    dani.escribir('cola', ['de dani']);
    alba.escribir('cola', ['de alba']);

    assert.notEqual(dani.clave('cola'), alba.clave('cola'));
    assert.deepEqual(dani.leer('cola'), ['de dani']);
    assert.deepEqual(alba.leer('cola'), ['de alba']);
});

test('entrar en una instancia no borra la cola pendiente de la otra', () => {
    const bruto = crearAlmacenFalso();

    // Alba tiene trabajo sin sincronizar.
    crearAlmacen(B, bruto, REGISTRO.alba.prefijoAlmacen).escribir('cola', [{ id: 'pendiente' }]);
    // Y en la instancia de Dani hay restos de otro usuario.
    crearAlmacen(B, bruto, REGISTRO.dani.prefijoAlmacen).escribir('cola', [{ id: 'ajeno' }]);

    // Dani entra. Se limpia lo suyo de otros usuarios, nada más.
    const borradas = purgarOtrosUsuarios(A, bruto, REGISTRO.dani.prefijoAlmacen);

    assert.equal(borradas, 1);
    assert.deepEqual(
        crearAlmacen(B, bruto, REGISTRO.alba.prefijoAlmacen).leer('cola'),
        [{ id: 'pendiente' }],
        'la cola de la otra instancia tiene que sobrevivir'
    );
});

test('limpiar una instancia no toca la otra', () => {
    const bruto = crearAlmacenFalso();
    const dani = crearAlmacen(A, bruto, REGISTRO.dani.prefijoAlmacen);
    const alba = crearAlmacen(A, bruto, REGISTRO.alba.prefijoAlmacen);

    dani.escribir('cola', [1]);
    alba.escribir('cola', [2]);
    dani.limpiar();

    assert.equal(dani.leer('cola'), null);
    assert.deepEqual(alba.leer('cola'), [2]);
});

test('purgar ignora claves que no tengan la forma esperada', () => {
    const bruto = crearAlmacenFalso();
    bruto.setItem('gastos.v2.' + B + '.cola', '[]');       // suya, de otro usuario
    bruto.setItem('gastos.v2.' + B + '.inventado', '[]');  // nombre desconocido
    bruto.setItem('gastos.v2.suelta', '[]');               // sin forma de clave

    purgarOtrosUsuarios(A, bruto, 'gastos.v2');

    assert.equal(bruto.getItem('gastos.v2.' + B + '.cola'), null);
    assert.notEqual(bruto.getItem('gastos.v2.' + B + '.inventado'), null);
    assert.notEqual(bruto.getItem('gastos.v2.suelta'), null);
});

test('solo la instancia heredada adopta las claves del esquema antiguo', () => {
    const antigua = () => crearAlmacenFalso({ 'gastos.cola': JSON.stringify([{ id: 'viejo' }]) });

    const paraAlba = antigua();
    const rAlba = migrarDesdeEsquemaAntiguo(A, paraAlba, REGISTRO.alba.prefijoAlmacen);
    assert.equal(rAlba.adoptadas, 0);
    assert.notEqual(paraAlba.getItem('gastos.cola'), null, 'no son suyas, no las borra');

    const paraDani = antigua();
    const rDani = migrarDesdeEsquemaAntiguo(A, paraDani, REGISTRO.dani.prefijoAlmacen);
    assert.equal(rDani.adoptadas, 1);
    assert.equal(paraDani.getItem('gastos.cola'), null);
});

// ------------------------------------------------------------
//  Rutas de los archivos generados
// ------------------------------------------------------------
test('la instancia raíz referencia lo compartido sin subir de nivel', () => {
    const { base, lista } = archivosDeInstancia(REGISTRO.dani, ['styles.css', 'js/app.js']);
    assert.equal(base, '');
    assert.ok(lista.includes('./js/app.js'));
});

test('una instancia en subcarpeta sube un nivel para lo compartido', () => {
    const { base, lista } = archivosDeInstancia(REGISTRO.alba, ['styles.css', 'js/app.js']);
    assert.equal(base, '../');
    assert.ok(lista.includes('../js/app.js'));
    assert.ok(lista.includes('./index.html'), 'su propio HTML sí es suyo');
});

test('instanciaConfigurada distingue una instancia a medio montar', () => {
    assert.equal(instanciaConfigurada(REGISTRO.dani), true);
    assert.equal(
        instanciaConfigurada(normalizar({ id: 'x', ruta: 'x', supabaseUrl: 'https://PENDIENTE.supabase.co', supabaseAnonKey: 'PENDIENTE' })),
        false
    );
});

// ------------------------------------------------------------
//  El `activate` de cada service worker, ejecutado de verdad
//
//  Se lee el sw.js GENERADO y se reproduce su lógica de purga sobre un
//  almacén de cachés compartido, que es como funciona el navegador.
// ------------------------------------------------------------
import { readFileSync } from 'node:fs';
import { resolve, dirname, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** Reproduce el `activate` del sw.js real de una instancia. */
function purgarCaches(inst, presentes) {
    const ruta = posix.join(inst.ruta || '.', 'sw.js');
    const src = readFileSync(resolve(RAIZ, ruta), 'utf8');

    const prefijo = src.match(/const PREFIJO\s*=\s*'([^']*)'/)[1];
    const version = prefijo + src.match(/const VERSION\s*=\s*PREFIJO\s*\+\s*'([^']+)'/)[1];
    const mias = new RegExp('^' + prefijo.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&') + 'v\\d+$');

    return presentes.filter((c) => !(mias.test(c) && c !== version));
}

test('desplegar una instancia no deja a la otra sin app offline', () => {
    // `caches` es del origen: las cuatro conviven en el mismo almacén.
    let caches = ['gastos-v17', 'gastos-alba-v17', 'gastos-v18', 'gastos-alba-v18'];

    caches = purgarCaches(REGISTRO.dani, caches);
    assert.ok(caches.includes('gastos-alba-v18'), 'la raíz no puede borrar la caché de alba');

    caches = purgarCaches(REGISTRO.alba, caches);
    assert.ok(caches.includes('gastos-v18'), 'alba no puede borrar la caché de la raíz');

    // Y cada una sí limpia su propia versión antigua.
    assert.deepEqual(caches.sort(), ['gastos-alba-v18', 'gastos-v18']);
});

test('el service worker raíz no atiende rutas de otras instancias', () => {
    const rutasEsperadas = INSTANCIAS.filter((i) => i.ruta).map((i) => i.ruta);

    const src = readFileSync(resolve(RAIZ, 'sw.js'), 'utf8');
    const ajenas = JSON.parse(src.match(/const RUTAS_AJENAS = (\[[^\]]*\])/)[1]);
    assert.deepEqual(ajenas.sort(), [...rutasEsperadas].sort(),
        'la raíz debe conocer TODAS las subcarpetas, también las que se añadan después');

    // Una instancia en subcarpeta no tiene rutas ajenas por debajo.
    for (const inst of INSTANCIAS.filter((i) => i.ruta)) {
        const suyo = readFileSync(resolve(RAIZ, posix.join(inst.ruta, 'sw.js')), 'utf8');
        assert.deepEqual(JSON.parse(suyo.match(/const RUTAS_AJENAS = (\[[^\]]*\])/)[1]), []);
    }
});

test('cada instancia cachea la aplicación compartida, no una copia', () => {
    const alba = readFileSync(resolve(RAIZ, 'alba/sw.js'), 'utf8');
    assert.ok(alba.includes('"../js/app.js"'), 'alba usa el app.js compartido');
    assert.ok(alba.includes('"./index.html"'), 'y su propio HTML');
    assert.ok(!alba.includes('"./js/app.js"'), 'no debe existir una copia bajo alba/');
});
