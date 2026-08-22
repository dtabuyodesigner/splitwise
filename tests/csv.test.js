// ============================================================
//  Importación y exportación CSV
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import {
    analizarCSV, trocearCSV, detectarSeparador, construirCSV, campoCSV, huella,
} from '../js/csv.js';
import { fechaDesde } from '../js/fechas.js';
import { aNumero } from '../js/dinero.js';

const YO = 'u-yo';
const OTRO = 'u-otro';

const ctx = {
    perfiles: [
        { id: YO, display_name: 'Dani' },
        { id: OTRO, display_name: 'Pilar' },
    ],
    yoId: YO,
    otroId: OTRO,
    grupoId: 'g1',
    hoy: '2026-08-23',
};

// ------------------------------------------------------------
//  Separadores
// ------------------------------------------------------------
test('detecta punto y coma', () => {
    assert.equal(detectarSeparador('Fecha;Concepto;Importe'), ';');
});

test('detecta coma', () => {
    assert.equal(detectarSeparador('Fecha,Concepto,Importe'), ',');
});

test('detecta tabulador', () => {
    assert.equal(detectarSeparador('Fecha\tConcepto\tImporte'), '\t');
});

test('una coma dentro de comillas no cuenta para elegir separador', () => {
    // Con el conteo ingenuo del monolito, esta cabecera elegía la coma.
    assert.equal(detectarSeparador('"Concepto, detalle";Importe'), ';');
});

test('importa un CSV separado por punto y coma', () => {
    const r = analizarCSV(
        'Fecha;Concepto;Importe;Pagador\n2026-01-15;Cena;24,50;Dani',
        ctx
    );
    assert.equal(r.error, undefined);
    assert.equal(r.gastos.length, 1);
    assert.equal(r.gastos[0].amount, 24.5);
    assert.equal(r.gastos[0].spent_on, '2026-01-15');
    assert.equal(r.gastos[0].paid_by, YO);
});

test('importa un CSV separado por comas con importes en punto decimal', () => {
    const r = analizarCSV(
        'Fecha,Concepto,Importe,Pagador\n15/01/2026,Taxi,12.30,Pilar',
        ctx
    );
    assert.equal(r.gastos.length, 1);
    assert.equal(r.gastos[0].amount, 12.3);
    assert.equal(r.gastos[0].paid_by, OTRO);
    assert.equal(r.gastos[0].spent_on, '2026-01-15');
});

// ------------------------------------------------------------
//  Comillas
// ------------------------------------------------------------
test('respeta las comillas y el separador que va dentro', () => {
    const r = analizarCSV(
        'Concepto;Importe\n"Cena; copas y taxi";40,00',
        ctx
    );
    assert.equal(r.gastos.length, 1);
    assert.equal(r.gastos[0].description, 'Cena; copas y taxi');
    assert.equal(r.gastos[0].amount, 40);
});

test('las comillas dobles escapadas se leen como una sola', () => {
    const filas = trocearCSV('a;"di ""hola"" fuerte";c', ';');
    assert.deepEqual(filas[0], ['a', 'di "hola" fuerte', 'c']);
});

test('un salto de línea dentro de comillas no parte la fila', () => {
    const filas = trocearCSV('a;"linea1\nlinea2";c', ';');
    assert.equal(filas.length, 1);
    assert.equal(filas[0][1], 'linea1\nlinea2');
});

// ------------------------------------------------------------
//  Fechas
// ------------------------------------------------------------
test('interpreta los formatos de fecha habituales', () => {
    assert.equal(fechaDesde('2026-03-04'), '2026-03-04');
    assert.equal(fechaDesde('2026/3/4'), '2026-03-04');
    assert.equal(fechaDesde('04/03/2026'), '2026-03-04');
    assert.equal(fechaDesde('4-3-26'), '2026-03-04');
    assert.equal(fechaDesde('04.03.2026'), '2026-03-04');
});

test('25/12/2026 se entiende como día 25, no como mes 25', () => {
    assert.equal(fechaDesde('25/12/2026'), '2026-12-25');
});

test('una fecha ilegible cae en la fecha de hoy, no rompe la importación', () => {
    assert.equal(fechaDesde('el martes'), null);
    const r = analizarCSV('Fecha;Concepto;Importe\nel martes;Café;2,00', ctx);
    assert.equal(r.gastos[0].spent_on, '2026-08-23');
});

// ------------------------------------------------------------
//  Importes
// ------------------------------------------------------------
test('lee importes en formato español y anglosajón', () => {
    assert.equal(aNumero('24,50'), 24.5);
    assert.equal(aNumero('24.50'), 24.5);
    assert.equal(aNumero('1.234,56'), 1234.56);
    assert.equal(aNumero('1,234.56'), 1234.56);
    assert.equal(aNumero('12 €'), 12);
});

test('resuelve sumas escritas en el campo de importe', () => {
    assert.equal(aNumero('15 + 4,20 + 8'), 27.2);
    assert.equal(aNumero('10*3'), 30);
    assert.equal(aNumero('(10+5)/2'), 7.5);
});

test('el importe se calcula con un evaluador propio, no con Function()', () => {
    // El monolito hacía Function('return (' + entrada + ')')(). Ahora hay un
    // analizador aritmético cerrado: nada que no sea número u operador entra.
    assert.ok(Number.isNaN(aNumero('alert(1)')), 'texto con letras no se evalúa');
    assert.ok(Number.isNaN(aNumero('this')));
    assert.ok(Number.isNaN(aNumero('constructor')));

    // Expresiones aritméticas mal formadas devuelven NaN desde el evaluador.
    // (Después queda el respaldo de parseFloat, que es el comportamiento de
    // siempre para entradas a medio escribir como "12" o "1+".)
    assert.ok(Number.isNaN(aNumero('(1+2')), 'paréntesis sin cerrar');
    assert.equal(aNumero('1/0'), 1, 'dividir entre cero no produce Infinity');

    // Y el efecto que importa: ningún valor devuelto es Infinity ni una
    // función, solo números redondeados a céntimos o NaN.
    for (const entrada of ['1/0', '999999999*999999999', '2**64', 'alert(1)', '1;2']) {
        const v = aNumero(entrada);
        assert.ok(Number.isNaN(v) || Number.isFinite(v), entrada + ' → ' + v);
    }
});

test('un importe ilegible se reporta como fallo, no se inventa', () => {
    const r = analizarCSV('Concepto;Importe\nCena;no se sabe\nTaxi;10,00', ctx);
    assert.equal(r.gastos.length, 1);
    assert.equal(r.fallos.length, 1);
    assert.match(r.fallos[0], /Línea 2/);
});

// ------------------------------------------------------------
//  Reparto y categorías
// ------------------------------------------------------------
test('interpreta la columna de reparto', () => {
    const csv = [
        'Concepto;Importe;Pagador;Reparto',
        'A;10;Dani;a medias',
        'B;10;Dani;solo Dani',
        'C;10;Dani;solo Pilar',
        'D;10;Dani;70/30',
    ].join('\n');
    const r = analizarCSV(csv, ctx);
    assert.deepEqual(r.gastos.map((g) => g.payer_share), [0.5, 1, 0, 0.7]);
});

test('deduce la categoría por el concepto cuando no viene', () => {
    const r = analizarCSV('Concepto;Importe\nGasolina;60,00\nMercadona;40,00', ctx);
    assert.equal(r.gastos[0].category, 'coche');
    assert.equal(r.gastos[1].category, 'súper');
});

test('un nombre con paréntesis no rompe la importación', () => {
    // El monolito construía la regex sin escapar el display_name (R13).
    const conParentesis = {
        ...ctx,
        perfiles: [{ id: YO, display_name: 'Dani (casa)' }, { id: OTRO, display_name: 'Pilar' }],
    };
    const r = analizarCSV('Concepto;Importe;Reparto\nCena;10;solo Dani (casa)', conParentesis);
    assert.equal(r.error, undefined);
    assert.equal(r.gastos.length, 1);
});

// ------------------------------------------------------------
//  Idempotencia
// ------------------------------------------------------------
test('reimportar el mismo CSV da los mismos client_id', () => {
    const csv = 'Fecha;Concepto;Importe;Pagador\n2026-01-15;Cena;24,50;Dani\n2026-01-16;Taxi;10,00;Pilar';
    const a = analizarCSV(csv, ctx).gastos.map((g) => g.client_id);
    const b = analizarCSV(csv, ctx).gastos.map((g) => g.client_id);
    assert.deepEqual(a, b);
    assert.equal(new Set(a).size, 2, 'y son distintos entre sí');
    assert.ok(a.every((c) => c.startsWith('imp:')));
});

test('el client_id cambia si cambia el grupo de destino', () => {
    const csv = 'Fecha;Concepto;Importe\n2026-01-15;Cena;24,50';
    const enG1 = analizarCSV(csv, ctx).gastos[0].client_id;
    const enG2 = analizarCSV(csv, { ...ctx, grupoId: 'g2' }).gastos[0].client_id;
    assert.notEqual(enG1, enG2);
});

test('huella() es determinista', () => {
    assert.equal(huella('mismo texto'), huella('mismo texto'));
    assert.notEqual(huella('a'), huella('b'));
    assert.equal(huella('x').length, 32, '128 bits en hexadecimal');
});

test('huella() no colisiona en un corpus grande', () => {
    // El djb2 de 32 bits del monolito producía 7 colisiones en 120.000
    // filas, alguna entre grupos distintos. Como client_id es único en toda
    // la tabla, una colisión hacía que el upsert SOBRESCRIBIERA un gasto
    // existente en lugar de insertar el nuevo.
    const vistos = new Map();
    let colisiones = 0;

    for (let g = 0; g < 3; g++) {
        for (let i = 1; i <= 40000; i++) {
            const clave = ['grupo' + g, i, '2026-01-01', 'Gasto ' + i, 10 + (i % 50), 'u-yo'].join('|');
            const h = huella(clave);
            if (vistos.has(h) && vistos.get(h) !== clave) colisiones++;
            else vistos.set(h, clave);
        }
    }

    assert.equal(colisiones, 0, '120.000 filas sin ninguna colisión');
});

test('dos filas distintas del mismo CSV nunca comparten client_id', () => {
    // Si dos filas del mismo lote de 100 compartieran client_id, PostgreSQL
    // rechazaría el lote entero con
    // "ON CONFLICT DO UPDATE command cannot affect row a second time".
    const filas = ['Fecha;Concepto;Importe;Pagador'];
    for (let i = 0; i < 500; i++) filas.push('2026-01-15;Café;1,20;Dani');

    const r = analizarCSV(filas.join('\n'), ctx);
    const ids = r.gastos.map((g) => g.client_id);

    assert.equal(ids.length, 500);
    assert.equal(new Set(ids).size, 500, 'incluso con 500 filas idénticas salvo la posición');
});

// ------------------------------------------------------------
//  Errores de cabecera
// ------------------------------------------------------------
test('sin columna de importe se explica el problema en lugar de importar mal', () => {
    const r = analizarCSV('Concepto;Notas\nCena;rica', ctx);
    assert.ok(r.error);
    assert.match(r.error, /columnas/i);
});

test('un CSV vacío no revienta', () => {
    assert.ok(analizarCSV('', ctx).error);
    assert.ok(analizarCSV('   \n  ', ctx).error);
});

test('las filas de total del propio export se ignoran', () => {
    const csv = 'Concepto;Importe;Reparto\nCena;10,00;a medias\n;10,00;Total gastos';
    const r = analizarCSV(csv, ctx);
    assert.equal(r.gastos.length, 1);
});

// ------------------------------------------------------------
//  Exportación
// ------------------------------------------------------------
test('el CSV exportado entrecomilla lo que lleva el separador', () => {
    assert.equal(campoCSV('Cena; copas'), '"Cena; copas"');
    assert.equal(campoCSV('di "hola"'), '"di ""hola"""');
    assert.equal(campoCSV('normal'), 'normal');
});

test('exportar e importar de vuelta conserva importes, fechas y reparto', () => {
    const gastos = [
        { spent_on: '2026-01-15', description: 'Cena; copas', category: 'comer fuera',
          paid_by: YO, payer_share: 0.5, amount: 24.5 },
        { spent_on: '2026-01-16', description: 'Hotel', category: 'alojamiento',
          paid_by: OTRO, payer_share: 1, amount: 120 },
    ];
    const nombreDe = (id) => (id === YO ? 'Dani' : 'Pilar');
    const otroDe = (id) => (id === YO ? OTRO : YO);

    const csv = construirCSV({ gastos, liquidaciones: [], total: 144.5 }, nombreDe, otroDe);
    const vuelta = analizarCSV(csv, ctx);

    assert.equal(vuelta.gastos.length, 2);
    assert.deepEqual(vuelta.gastos.map((g) => g.amount).sort((a, b) => a - b), [24.5, 120]);
    assert.deepEqual(vuelta.gastos.map((g) => g.spent_on), ['2026-01-15', '2026-01-16']);
    assert.equal(vuelta.gastos[0].description, 'Cena; copas');
    assert.equal(vuelta.gastos[0].paid_by, YO);
    assert.equal(vuelta.gastos[1].paid_by, OTRO);
    assert.equal(vuelta.gastos[1].payer_share, 1);
});
