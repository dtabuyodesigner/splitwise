// ============================================================
//  Escrituras: qué ve el usuario y qué queda en el estado local
//  cuando el servidor acepta o rechaza el cambio.
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { crearAlmacen } from '../js/almacen.js';
import { ColaOffline, TIPO } from '../js/offline-queue.js';
import { crearApunte, editarApunte, borrarApunte } from '../js/mutaciones.js';
import { CLASE } from '../js/errores.js';
import {
    crearSupabaseFalso, crearAlmacenFalso,
    ERROR_RLS, ERROR_SESION, ERROR_RED, ERROR_VALIDACION,
} from './ayudas/supabase-falso.mjs';

const A = 'usuario-A';

function montar(inicial) {
    const sb = crearSupabaseFalso(inicial);
    const almacen = crearAlmacen(A, crearAlmacenFalso());
    const cola = new ColaOffline({ almacen, userId: A });
    return { sb, cola };
}

const fila = (extra = {}) => ({
    group_id: 'g1', paid_by: A, amount: 20, description: 'Súper',
    category: 'súper', payer_share: 0.5, spent_on: '2026-01-01',
    client_id: 'c1', ...extra,
});

// ------------------------------------------------------------
//  Alta
// ------------------------------------------------------------
test('alta con conexión: se guarda en el servidor y NO se encola', async () => {
    const { sb, cola } = montar();
    const r = await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: true });

    assert.equal(r.estado, 'servidor');
    assert.equal(cola.longitud, 0);
    assert.equal(sb.tablas.expenses.length, 1);
});

test('alta sin conexión: queda pendiente en la cola', async () => {
    const { sb, cola } = montar();
    const r = await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: false });

    assert.equal(r.estado, 'pendiente');
    assert.equal(cola.longitud, 1);
    assert.equal(sb.tablas.expenses.length, 0);
});

test('alta con fallo de red: pendiente, y sí se encola', async () => {
    const { sb, cola } = montar();
    sb.fallar('expenses.insert', ERROR_RED);

    const r = await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: true });
    assert.equal(r.estado, 'pendiente');
    assert.equal(cola.longitud, 1);
});

test('alta rechazada por RLS: error visible y NO entra en la cola', async () => {
    const { sb, cola } = montar();
    sb.fallar('expenses.insert', ERROR_RLS);

    const r = await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: true });

    assert.equal(r.estado, 'error');
    assert.equal(r.clase, CLASE.PERMISO);
    assert.equal(cola.longitud, 0, 'este es el fallo que corrige la fase 1');
    assert.equal(sb.tablas.expenses.length, 0);
});

test('alta con la sesión caducada: estado propio y NO entra en la cola', async () => {
    const { sb, cola } = montar();
    sb.fallar('expenses.insert', ERROR_SESION);

    const r = await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: true });

    assert.equal(r.estado, 'sesion');
    assert.equal(r.clase, CLASE.SESION);
    assert.equal(cola.longitud, 0);
});

test('alta rechazada por una restricción: NO entra en la cola', async () => {
    const { sb, cola } = montar();
    sb.fallar('expenses.insert', ERROR_VALIDACION);

    const r = await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: true });
    assert.equal(r.estado, 'error');
    assert.equal(r.clase, CLASE.VALIDACION);
    assert.equal(cola.longitud, 0);
});

test('alta repetida con el mismo client_id no duplica el gasto', async () => {
    const { sb, cola } = montar();
    await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: true });
    const segunda = await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: true });

    assert.equal(segunda.estado, 'duplicado');
    assert.equal(sb.tablas.expenses.length, 1);
    assert.equal(cola.longitud, 0);
});

// ------------------------------------------------------------
//  Edición
// ------------------------------------------------------------
test('edición aceptada: el estado local refleja el cambio', async () => {
    const { sb, cola } = montar({ expenses: [{ id: 'e1', ...fila() }] });
    const lista = [{ id: 'e1', ...fila() }];

    const r = await editarApunte(sb, {
        tabla: 'expenses', lista, id: 'e1', cambios: { amount: 99 }, cola, online: true,
    });

    assert.equal(r.estado, 'servidor');
    assert.equal(lista[0].amount, 99);
    assert.equal(sb.tablas.expenses[0].amount, 99);
});

test('edición rechazada por RLS: se DESHACE el cambio en pantalla', async () => {
    const { sb, cola } = montar({ expenses: [{ id: 'e1', ...fila() }] });
    const lista = [{ id: 'e1', ...fila() }];
    sb.fallar('expenses.update', ERROR_RLS);

    const r = await editarApunte(sb, {
        tabla: 'expenses', lista, id: 'e1', cambios: { amount: 99 }, cola, online: true,
    });

    assert.equal(r.estado, 'error');
    assert.equal(r.clase, CLASE.PERMISO);
    assert.equal(lista[0].amount, 20, 'el importe vuelve a ser el original');
    assert.equal(cola.longitud, 0);
    assert.equal(sb.tablas.expenses[0].amount, 20);
});

test('edición que no afecta a ninguna fila: se deshace y se avisa', async () => {
    // Sin error, pero la fila no existe (o RLS la esconde): el caso que el
    // monolito daba por bueno en silencio.
    const { sb, cola } = montar({ expenses: [] });
    const lista = [{ id: 'fantasma', ...fila() }];

    const r = await editarApunte(sb, {
        tabla: 'expenses', lista, id: 'fantasma', cambios: { amount: 99 }, cola, online: true,
    });

    assert.equal(r.estado, 'error');
    assert.equal(r.clase, CLASE.PERMISO);
    assert.equal(lista[0].amount, 20);
});

test('edición sin conexión: queda pendiente y se envía al reconectar', async () => {
    const { sb, cola } = montar({ expenses: [{ id: 'e1', ...fila() }] });
    const lista = [{ id: 'e1', ...fila() }];

    const r = await editarApunte(sb, {
        tabla: 'expenses', lista, id: 'e1', cambios: { amount: 55 }, cola, online: false,
    });

    assert.equal(r.estado, 'pendiente');
    assert.equal(lista[0].pendiente, true);
    assert.equal(cola.longitud, 1);

    await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(sb.tablas.expenses[0].amount, 55);
});

test('editar sin conexión un apunte que aún no se ha enviado no pierde el cambio', async () => {
    // El caso R6: en el monolito se encolaba un update contra un id que el
    // servidor no conocía, y la edición se perdía en silencio.
    const { sb, cola } = montar();
    const lista = [];

    await crearApunte(sb, { tabla: 'expenses', fila: fila(), cola, online: false });
    lista.push({ ...fila(), id: 'c1', pendiente: true });

    const r = await editarApunte(sb, {
        tabla: 'expenses', lista, id: 'c1', cambios: { amount: 77 },
        cola, online: false, pendiente: true,
    });

    assert.equal(r.estado, 'pendiente');
    assert.equal(cola.longitud, 1, 'sigue habiendo una sola tarea');
    assert.equal(cola.tareas[0].tipo, TIPO.INSERTAR);

    await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(sb.tablas.expenses.length, 1);
    assert.equal(sb.tablas.expenses[0].amount, 77);
});

// ------------------------------------------------------------
//  Borrado
// ------------------------------------------------------------
test('borrado aceptado: desaparece de pantalla y del servidor', async () => {
    const { sb, cola } = montar({ expenses: [{ id: 'e1', ...fila() }] });
    const lista = [{ id: 'e1', ...fila() }];

    const r = await borrarApunte(sb, { tabla: 'expenses', lista, id: 'e1', cola, online: true });

    assert.equal(r.estado, 'servidor');
    assert.equal(lista.length, 0);
    assert.equal(sb.tablas.expenses.length, 0);
});

test('borrado rechazado por RLS: el gasto VUELVE a la lista', async () => {
    const { sb, cola } = montar({ expenses: [{ id: 'e1', ...fila() }] });
    const lista = [{ id: 'e1', ...fila() }];
    sb.fallar('expenses.delete', ERROR_RLS);

    const r = await borrarApunte(sb, { tabla: 'expenses', lista, id: 'e1', cola, online: true });

    assert.equal(r.estado, 'error');
    assert.equal(lista.length, 1, 'no se queda borrado solo en la pantalla');
    assert.equal(lista[0].id, 'e1');
    assert.equal(sb.tablas.expenses.length, 1);
    assert.equal(cola.longitud, 0);
});

test('borrado que no afecta a ninguna fila: se restaura y se avisa', async () => {
    const { sb, cola } = montar({ expenses: [] });
    const lista = [{ id: 'fantasma', ...fila() }];

    const r = await borrarApunte(sb, { tabla: 'expenses', lista, id: 'fantasma', cola, online: true });

    assert.equal(r.estado, 'error');
    assert.equal(lista.length, 1);
});

test('borrar sin conexión un apunte ya enviado deja el borrado en cola', async () => {
    const { sb, cola } = montar({ expenses: [{ id: 'e1', ...fila() }] });
    const lista = [{ id: 'e1', ...fila() }];

    const r = await borrarApunte(sb, { tabla: 'expenses', lista, id: 'e1', cola, online: false });

    assert.equal(r.estado, 'pendiente');
    assert.equal(cola.longitud, 1);
    assert.equal(cola.tareas[0].tipo, TIPO.BORRAR);

    await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(sb.tablas.expenses.length, 0);
});

test('el saldo tras un rechazo es el mismo que antes de intentarlo', async () => {
    const { calcularSaldo } = await import('../js/balances.js');
    const personas = { yoId: A, otroId: 'otro' };

    const { sb, cola } = montar({ expenses: [{ id: 'e1', ...fila({ amount: 100 }) }] });
    const lista = [{ id: 'e1', ...fila({ amount: 100 }) }];

    const antes = calcularSaldo(lista, [], personas);
    sb.fallar('expenses.delete', ERROR_RLS);
    await borrarApunte(sb, { tabla: 'expenses', lista, id: 'e1', cola, online: true });

    assert.equal(calcularSaldo(lista, [], personas), antes);
    assert.equal(antes, 50);
});
