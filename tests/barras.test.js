// ============================================================
//  Las barras de botones no pueden cortar ninguno
//
//  El fallo real: `.utiles` era `overflow-x: auto` con
//  `scrollbar-width: none`. A 560 px de ancho medía 696 px de contenido, así
//  que el quinto botón —«Backup JSON», el de la derecha de «Importar CSV»—
//  quedaba cortado, y NADA indicaba que se podía desplazar. Un scroll
//  horizontal invisible es un botón que no existe para quien no lo descubre
//  por accidente.
//
//  Aquí no hay navegador, así que no se mide geometría: se comprueba que el
//  CSS no vuelve a declarar el patrón que lo causaba, y que sí declara el
//  que lo arregla. Es lo que puede correr en el CI, y caza la regresión.
//  Las medidas reales se toman en el navegador.
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..');
const css = readFileSync(join(raiz, 'styles.css'), 'utf8');
const html = readFileSync(join(raiz, 'index.html'), 'utf8');

/** Devuelve el cuerpo de una regla de primer nivel, sin anidamientos. */
function regla(selector) {
    const i = css.indexOf(selector + ' {');
    assert.notEqual(i, -1, `no encuentro la regla ${selector}`);
    const abre = css.indexOf('{', i);
    const cierra = css.indexOf('}', abre);
    return css.slice(abre + 1, cierra);
}

const BARRAS = ['.utiles', '.acciones'];

for (const barra of BARRAS) {
    test(`${barra} deja que los botones salten de línea`, () => {
        const cuerpo = regla(barra);
        assert.match(cuerpo, /flex-wrap:\s*wrap/,
            `${barra} necesita flex-wrap: wrap, o el último botón se sale`);
    });

    test(`${barra} no esconde un scroll horizontal`, () => {
        const cuerpo = regla(barra);
        // `overflow-x: auto` por sí solo no es el problema; el problema es
        // ocultar la barra, porque entonces no hay ninguna señal de que
        // queda contenido fuera.
        const desplaza = /overflow-x:\s*(auto|scroll)/.test(cuerpo);
        const ocultaBarra = new RegExp(
            `\\${barra}::-webkit-scrollbar\\s*\\{[^}]*display:\\s*none`,
        ).test(css) || /scrollbar-width:\s*none/.test(cuerpo);

        assert.ok(!(desplaza && ocultaBarra),
            `${barra} desplaza en horizontal con la barra oculta: `
            + 'lo que quede fuera será invisible e inalcanzable');
    });
}

test('los cinco botones de utilidades siguen estando', () => {
    for (const id of ['botonStats', 'botonCompartir', 'botonExportar',
                      'botonImportar', 'botonBackupJSON']) {
        assert.ok(html.includes(`id="${id}"`), `falta ${id}`);
    }
});

test('«Trasladar saldo» está en la barra de acciones y se lee entero', () => {
    assert.match(html, /id="botonTrasladar"[^>]*>Trasladar saldo</,
        'el botón tiene que llevar su texto completo, no una abreviatura');
    const cuerpo = regla('.acciones__secundario');
    assert.match(cuerpo, /white-space:\s*nowrap/,
        'sin nowrap el texto se parte a mitad de palabra al envolver');
});

test('no se encoge el texto de los botones para que quepan', () => {
    // Reducir la fuente para evitar el desbordamiento es la salida fácil, y
    // rompe la legibilidad. Se comprueba que no se ha hecho.
    const util = regla('.util');
    const fuente = /font-size:\s*(\d+)px/.exec(util);
    assert.ok(fuente && Number(fuente[1]) >= 13,
        'la letra de los botones de utilidades no puede bajar de 13px');
});
