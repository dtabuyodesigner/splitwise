// ============================================================
//  Dictado natural
//  Red de seguridad para la modularización: el mismo texto tiene que
//  seguir dando el mismo resultado que en el monolito.
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { interpretarDictado } from '../js/voice.js';

const YO = 'u-yo';
const OTRO = 'u-otro';
const ctx = {
    perfiles: [{ id: YO, display_name: 'Dani' }, { id: OTRO, display_name: 'Pilar' }],
    yoId: YO,
    ahora: new Date('2026-08-23T12:00:00'),
};

const leer = (t) => interpretarDictado(t, ctx);

test('saca el importe con céntimos dichos de varias formas', () => {
    assert.equal(leer('cena 24 con 50').importe, 24.5);
    assert.equal(leer('cena 24 euros con 50').importe, 24.5);
    assert.equal(leer('cena 24,50').importe, 24.5);
    assert.equal(leer('cena 24 euros').importe, 24);
});

test('saca quién pagó', () => {
    assert.equal(leer('pagué yo la cena 30').pagador, YO);
    assert.equal(leer('pagó Pilar la cena 30').pagador, OTRO);
    assert.equal(leer('invitó Pilar 20').pagador, OTRO);
});

test('saca la categoría por las pistas del concepto', () => {
    assert.equal(leer('gasolina 60').categoria, 'coche');
    assert.equal(leer('mercadona 45').categoria, 'súper');
    assert.equal(leer('hotel 120').categoria, 'alojamiento');
    assert.equal(leer('taxi 12').categoria, 'transporte');
});

test('saca el reparto', () => {
    assert.equal(leer('cena 30 a medias').asume, 'ambos');
    assert.equal(leer('cena 30').asume, 'ambos', 'a medias por defecto');
});

test('"solo para mí" se entiende aunque lleve tilde', () => {
    // En el monolito el \\b final no cerraba tras una vocal acentuada, así
    // que "solo para mí" se guardaba a medias. Eso daba un saldo incorrecto.
    assert.equal(leer('farmacia 12 solo para mí').asume, YO);
    assert.equal(leer('farmacia 12 solo mío').asume, YO);
    assert.equal(leer('farmacia 12 es mío').asume, YO);
});

test('entiende ayer y hoy', () => {
    assert.equal(leer('cena 30 ayer').fecha, '2026-08-22');
    assert.equal(leer('cena 30 hoy').fecha, '2026-08-23');
});

test('deja un concepto legible sin las palabras de relleno', () => {
    const r = leer('pagué yo la cena en el bar 24 con 50');
    assert.ok(r.concepto);
    assert.ok(!/^(la|el|en)\b/i.test(r.concepto), 'no empieza por relleno: ' + r.concepto);
    assert.equal(r.concepto[0], r.concepto[0].toUpperCase());
});

test('el concepto sale de lo dicho, con la inicial en mayúscula', () => {
    assert.equal(leer('gasolina 60').concepto, 'Gasolina');
    assert.equal(leer('pagué yo 20 mercadona').concepto, 'Mercadona');
});

test('un dictado vacío devuelve null', () => {
    assert.equal(leer(''), null);
    assert.equal(leer('   '), null);
});

test('un nombre con caracteres de regex no rompe el dictado', () => {
    const hostil = {
        ...ctx,
        perfiles: [{ id: YO, display_name: 'Dani (a+)+' }, { id: OTRO, display_name: 'Pilar' }],
    };
    assert.doesNotThrow(() => interpretarDictado('cena 20 pagó Pilar', hostil));
});
