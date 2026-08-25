// ============================================================
//  Clasificación de errores
//  Lo que decide si algo entra o no en la cola offline.
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { clasificarError, esRecuperable, CLASE, mensajeResultado } from '../js/errores.js';
import {
    ERROR_RLS, ERROR_SESION, ERROR_RED, ERROR_VALIDACION, ERROR_DUPLICADO, ERROR_SERVIDOR,
} from './ayudas/supabase-falso.mjs';

test('estar sin conexión siempre es recuperable', () => {
    const c = clasificarError(ERROR_VALIDACION, { online: false });
    assert.equal(c.clase, CLASE.RED);
    assert.equal(c.recuperable, true);
});

test('"Failed to fetch" es un fallo de red', () => {
    const c = clasificarError(ERROR_RED, { online: true });
    assert.equal(c.clase, CLASE.RED);
    assert.equal(c.recuperable, true);
});

test('un 5xx del servidor es recuperable', () => {
    assert.equal(clasificarError(ERROR_SERVIDOR).clase, CLASE.RED);
});

test('un 429 es recuperable', () => {
    assert.equal(clasificarError({ status: 429, message: 'too many requests' }).clase, CLASE.RED);
});

test('un timeout es recuperable', () => {
    assert.equal(clasificarError({ name: 'AbortError', message: 'aborted' }).clase, CLASE.RED);
    assert.equal(clasificarError({ message: 'network timeout' }).clase, CLASE.RED);
});

test('42501 es un rechazo de RLS y NO es recuperable', () => {
    const c = clasificarError(ERROR_RLS);
    assert.equal(c.clase, CLASE.PERMISO);
    assert.equal(c.recuperable, false);
    assert.equal(esRecuperable(c.clase), false);
});

test('un 403 sin código también es rechazo de permisos', () => {
    assert.equal(clasificarError({ status: 403, message: 'forbidden' }).clase, CLASE.PERMISO);
});

test('JWT caducado se clasifica como sesión, no como permiso', () => {
    const c = clasificarError(ERROR_SESION);
    assert.equal(c.clase, CLASE.SESION);
    assert.equal(c.recuperable, false);
});

test('un 401 sin código es sesión', () => {
    assert.equal(clasificarError({ status: 401, message: 'unauthorized' }).clase, CLASE.SESION);
});

test('violación de CHECK es validación y no se reintenta', () => {
    const c = clasificarError(ERROR_VALIDACION);
    assert.equal(c.clase, CLASE.VALIDACION);
    assert.equal(c.recuperable, false);
});

test('violación de clave foránea es validación', () => {
    assert.equal(clasificarError({ code: '23503', message: 'fk violation' }).clase, CLASE.VALIDACION);
});

test('violación de unicidad se trata como duplicado, no como fallo', () => {
    const c = clasificarError(ERROR_DUPLICADO);
    assert.equal(c.clase, CLASE.DUPLICADO);
    assert.equal(c.recuperable, false);
});

test('lo que no encaja en nada queda como desconocido y no se encola', () => {
    const c = clasificarError({ message: 'algo raro ha pasado' });
    assert.equal(c.clase, CLASE.DESCONOCIDO);
    assert.equal(c.recuperable, false);
});

test('null y undefined no rompen la clasificación', () => {
    assert.equal(clasificarError(null).clase, CLASE.DESCONOCIDO);
    assert.equal(clasificarError(undefined).clase, CLASE.DESCONOCIDO);
});

test('los cuatro estados de la interfaz tienen mensaje propio', () => {
    const m = (estado) => mensajeResultado({ estado }, { sustantivo: 'Gasto' });
    assert.match(m('servidor'), /guardado/i);
    assert.match(m('pendiente'), /sin conexión/i);
    assert.match(m('sesion'), /sesión caducada/i);
    assert.notEqual(m('servidor'), m('pendiente'));
    assert.notEqual(m('pendiente'), m('sesion'));
});
