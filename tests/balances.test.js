// ============================================================
//  Saldos: repartos, liquidaciones, redondeo y volumen
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { calcularSaldo, delGrupo, totalesDelGrupo, sumar } from '../js/balances.js';

const YO = 'u-yo';
const OTRO = 'u-otro';
const G = 'g1';
const personas = { yoId: YO, otroId: OTRO };

const gasto = (amount, paid_by, payer_share = 0.5, extra = {}) =>
    ({ group_id: G, amount, paid_by, payer_share, spent_on: '2026-01-01', ...extra });

const pago = (amount, from_user, to_user) =>
    ({ group_id: G, amount, from_user, to_user, settled_on: '2026-01-01' });

test('gasto a medias: quien paga queda a favor por la mitad', () => {
    assert.equal(calcularSaldo([gasto(100, YO)], [], personas), 50);
    assert.equal(calcularSaldo([gasto(100, OTRO)], [], personas), -50);
});

test('reparto al 100 % del pagador: no genera deuda', () => {
    assert.equal(calcularSaldo([gasto(80, YO, 1)], [], personas), 0);
    assert.equal(calcularSaldo([gasto(80, OTRO, 1)], [], personas), 0);
});

test('reparto al 0 %: el gasto es entero del otro', () => {
    assert.equal(calcularSaldo([gasto(80, YO, 0)], [], personas), 80);
    assert.equal(calcularSaldo([gasto(80, OTRO, 0)], [], personas), -80);
});

test('reparto personalizado 70/30', () => {
    // Pago 100 y asumo el 70 %: el otro me debe 30.
    assert.equal(calcularSaldo([gasto(100, YO, 0.7)], [], personas), 30);
    // Lo paga el otro asumiendo el 30 %: yo le debo 70.
    assert.equal(calcularSaldo([gasto(100, OTRO, 0.3)], [], personas), -70);
});

test('reparto personalizado con decimales impares', () => {
    // 33,33 % de 99,99 → el otro asume 66,67 % = 66,6633 → 66,66 tras redondear
    const s = calcularSaldo([gasto(99.99, YO, 0.3333)], [], personas);
    assert.equal(s, 66.66);
});

test('varias liquidaciones se restan del saldo en ambos sentidos', () => {
    const gastos = [gasto(200, YO), gasto(100, OTRO)];   // 100 - 50 = +50 a mi favor
    assert.equal(calcularSaldo(gastos, [], personas), 50);

    const liquidaciones = [
        pago(20, OTRO, YO),   // me paga 20 → quedan 30
        pago(10, OTRO, YO),   // me paga 10 → quedan 20
        pago(5, YO, OTRO),    // le devuelvo 5 → 25
    ];
    assert.equal(calcularSaldo(gastos, liquidaciones, personas), 25);
});

test('una liquidación que salda del todo deja el saldo en cero', () => {
    assert.equal(calcularSaldo([gasto(100, YO)], [pago(50, OTRO, YO)], personas), 0);
});

test('las liquidaciones ajenas al par no alteran el saldo', () => {
    const ajena = { group_id: G, amount: 999, from_user: 'x', to_user: 'y', settled_on: '2026-01-01' };
    assert.equal(calcularSaldo([gasto(100, YO)], [ajena], personas), 50);
});

test('un gasto pagado por un tercero no se reparte entre este par', () => {
    // El monolito original lo repartía contra `perfiles.find(p => p.id !== paid_by)`,
    // es decir, un tercero arbitrario. Aquí se ignora explícitamente (R1).
    const deUnTercero = gasto(500, 'u-tercero');
    assert.equal(calcularSaldo([gasto(100, YO), deUnTercero], [], personas), 50);
});

test('sin segunda persona no se inventa un saldo', () => {
    assert.equal(calcularSaldo([gasto(100, YO)], [], { yoId: YO, otroId: null }), null);
    assert.equal(calcularSaldo([gasto(100, YO)], [], { yoId: YO, otroId: YO }), null);
});

// ------------------------------------------------------------
//  Redondeo monetario
// ------------------------------------------------------------
test('céntimo impar a medias: se redondea una sola vez al final', () => {
    // 0,01 / 2 = 0,005 → un único gasto redondea a 0,01 (medio hacia arriba)
    assert.equal(calcularSaldo([gasto(0.01, YO)], [], personas), 0.01);
    // Dos gastos iguales suman 0,01 exacto, sin duplicar el redondeo.
    assert.equal(calcularSaldo([gasto(0.01, YO), gasto(0.01, YO)], [], personas), 0.01);
});

test('mil gastos de 0,10 a medias no acumulan deriva binaria', () => {
    const gastos = Array.from({ length: 1000 }, () => gasto(0.1, YO));
    assert.equal(calcularSaldo(gastos, [], personas), 50);
});

test('importes con tres decimales implícitos no descuadran el total', () => {
    const gastos = [gasto(10.005, YO), gasto(10.005, YO)];
    // aCentimos redondea cada importe a céntimos antes de repartir.
    assert.equal(calcularSaldo(gastos, [], personas), 10.01);
});

test('sumar() no arrastra el error clásico de 0.1 + 0.2', () => {
    assert.equal(sumar([{ amount: 0.1 }, { amount: 0.2 }]), 0.3);
});

// ------------------------------------------------------------
//  Volumen: por encima de los límites que truncaban el saldo
// ------------------------------------------------------------
test('el saldo es exacto con más de 2500 gastos y más de 500 liquidaciones', () => {
    const gastos = [];
    for (let i = 0; i < 3000; i++) gastos.push(gasto(10, i % 2 === 0 ? YO : OTRO));
    // 1500 míos y 1500 suyos, todos a medias → se compensan: saldo 0.
    assert.equal(calcularSaldo(gastos, [], personas), 0);

    // Un gasto extra mío de 20 € → el otro me debe 10.
    gastos.push(gasto(20, YO));
    assert.equal(calcularSaldo(gastos, [], personas), 10);

    // 600 liquidaciones de 0,01 € a mi favor restan 6 €.
    const liquidaciones = Array.from({ length: 600 }, () => pago(0.01, OTRO, YO));
    assert.equal(calcularSaldo(gastos, liquidaciones, personas), 4);
});

test('truncar el conjunto SÍ cambiaría el saldo (justifica la paginación)', () => {
    // 2600 gastos: los 100 más antiguos son los que el limit(2500) perdía.
    const todos = [];
    for (let i = 0; i < 2500; i++) todos.push(gasto(10, YO, 1));      // no generan deuda
    for (let i = 0; i < 100; i++) todos.push(gasto(10, YO, 0));       // 10 € cada uno a mi favor

    assert.equal(calcularSaldo(todos, [], personas), 1000);
    // Con el corte antiguo (los 2500 primeros por fecha) el saldo sería 0.
    assert.equal(calcularSaldo(todos.slice(0, 2500), [], personas), 0);
});

// ------------------------------------------------------------
//  Filtrado y totales
// ------------------------------------------------------------
test('delGrupo compara los id como texto', () => {
    const filas = [{ group_id: 1 }, { group_id: '1' }, { group_id: 2 }];
    assert.equal(delGrupo(filas, '1').length, 2);
    assert.equal(delGrupo(filas, 1).length, 2);
    assert.equal(delGrupo(filas, null).length, 0);
});

test('totalesDelGrupo reparte lo adelantado por cada persona', () => {
    const gastos = [gasto(30, YO), gasto(12.35, OTRO), gasto(7.65, OTRO)];
    const { total, adelantado } = totalesDelGrupo(gastos, [{ id: YO }, { id: OTRO }]);
    assert.equal(total, 50);
    assert.equal(adelantado[YO], 30);
    assert.equal(adelantado[OTRO], 20);
});
