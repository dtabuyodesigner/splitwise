// ============================================================
//  Cola offline: qué entra, qué no, y de quién es
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { crearAlmacen, migrarDesdeEsquemaAntiguo, purgarOtrosUsuarios, PREFIJO } from '../js/almacen.js';
import { ColaOffline, TIPO, ejecutarTarea, MAX_INTENTOS } from '../js/offline-queue.js';
import { CLASE } from '../js/errores.js';
import {
    crearSupabaseFalso, crearAlmacenFalso,
    ERROR_RLS, ERROR_SESION, ERROR_RED, ERROR_VALIDACION,
} from './ayudas/supabase-falso.mjs';

const A = 'usuario-A';
const B = 'usuario-B';

const gasto = (client_id, extra = {}) => ({
    group_id: 'g1', paid_by: A, amount: 10, description: 'Cena',
    category: 'comer fuera', payer_share: 0.5, spent_on: '2026-01-01',
    client_id, ...extra,
});

function montar(userId = A, almacenBruto = crearAlmacenFalso()) {
    const almacen = crearAlmacen(userId, almacenBruto);
    return { almacenBruto, almacen, cola: new ColaOffline({ almacen, userId }) };
}

// ------------------------------------------------------------
//  Desconexión y reconexión
// ------------------------------------------------------------
test('sin conexión se encola, y al reconectar se envía y se vacía', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();

    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c2'));

    // Sin conexión no se intenta nada.
    const parado = await cola.vaciar(sb, { online: false, userIdSesion: A });
    assert.equal(parado.enviadas, 0);
    assert.equal(cola.longitud, 2);
    assert.equal(sb.tablas.expenses.length, 0);

    // Al volver la red se envía todo.
    const r = await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(r.enviadas, 2);
    assert.equal(cola.longitud, 0);
    assert.equal(sb.tablas.expenses.length, 2);
});

test('la cola sobrevive a recargar la página', async () => {
    const bruto = crearAlmacenFalso();
    const primera = montar(A, bruto);
    primera.cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    // Otra instancia leyendo el mismo almacén: es lo que hace un F5.
    const segunda = montar(A, bruto);
    assert.equal(segunda.cola.longitud, 1);
    assert.equal(segunda.cola.tareas[0].fila.client_id, 'c1');
});

test('un fallo de red deja la tarea en cola y se reintenta al reconectar', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    sb.fallar('expenses.upsert', ERROR_RED, 1);
    const primero = await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(primero.enviadas, 0);
    assert.equal(cola.pendientes.length, 1, 'sigue pendiente, no se marca como fallida');

    const segundo = await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(segundo.enviadas, 1);
    assert.equal(cola.longitud, 0);
});

// ------------------------------------------------------------
//  Errores que NO deben quedarse reintentando para siempre
// ------------------------------------------------------------
test('un rechazo de RLS deja de reintentarse y se marca como fallido', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    sb.fallar('expenses.upsert', ERROR_RLS);
    const r = await cola.vaciar(sb, { online: true, userIdSesion: A });

    assert.equal(r.enviadas, 0);
    assert.equal(r.rechazadas.length, 1);
    assert.equal(r.rechazadas[0].clase, CLASE.PERMISO);
    assert.equal(cola.fallidas.length, 1);
    assert.equal(cola.pendientes.length, 0, 'ya no cuenta como pendiente');

    // Un segundo intento no vuelve a llamar al servidor.
    const antes = sb.registro.length;
    await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(sb.registro.length, antes, 'no se reintenta lo irrecuperable');
});

test('una violación de restricción tampoco se reintenta eternamente', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    sb.fallar('expenses.upsert', ERROR_VALIDACION);
    const r = await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(r.rechazadas[0].clase, CLASE.VALIDACION);
    assert.equal(cola.fallidas.length, 1);
});

test('sesión caducada NO descarta la tarea: se reintenta al volver a entrar', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    sb.fallar('expenses.upsert', ERROR_SESION, 1);
    const r = await cola.vaciar(sb, { online: true, userIdSesion: A });

    assert.equal(r.sesionCaducada, true);
    assert.equal(r.enviadas, 0);
    assert.equal(cola.fallidas.length, 0, 'no se marca como fallida');
    assert.equal(cola.pendientes.length, 1);

    // Tras renovar la sesión, se envía.
    const r2 = await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(r2.enviadas, 1);
});

test('un duplicado por client_id se da por enviado (idempotencia)', async () => {
    const sb = crearSupabaseFalso({ expenses: [{ id: 'srv-x', client_id: 'c1', amount: 10 }] });
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    const r = await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(r.enviadas, 1);
    assert.equal(cola.longitud, 0);
    assert.equal(sb.tablas.expenses.length, 1, 'no se ha duplicado la fila');
});

test('vaciar dos veces a la vez no envía nada dos veces', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    for (let i = 0; i < 5; i++) cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c' + i));

    const [a, b] = await Promise.all([
        cola.vaciar(sb, { online: true, userIdSesion: A }),
        cola.vaciar(sb, { online: true, userIdSesion: A }),
    ]);

    assert.equal(a.enviadas + b.enviadas, 5);
    assert.equal(sb.tablas.expenses.length, 5);
});

test('la red que nunca vuelve no deja la tarea reintentándose para siempre', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));
    sb.fallar('expenses.upsert', ERROR_RED);

    for (let i = 0; i < MAX_INTENTOS - 1; i++) {
        await cola.vaciar(sb, { online: true, userIdSesion: A });
        assert.equal(cola.pendientes.length, 1, 'sigue intentándolo');
    }

    await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(cola.pendientes.length, 0, 'agotados los intentos, deja de reintentar');
    assert.equal(cola.fallidas.length, 1, 'pero NO se descarta: sigue ahí para el usuario');

    // Vuelve la red. Hace falta un reintento explícito, y entonces se envía.
    sb.dejarDeFallar('expenses.upsert');
    assert.equal((await cola.vaciar(sb, { online: true, userIdSesion: A })).enviadas, 0);

    cola.reintentarFallidas();
    assert.equal((await cola.vaciar(sb, { online: true, userIdSesion: A })).enviadas, 1);
    assert.equal(sb.tablas.expenses.length, 1, 'el gasto no se ha perdido');
});

test('descartar las fallidas las quita, y no toca las pendientes', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('rechazada'));
    sb.fallar('expenses.upsert', ERROR_RLS, 1);
    await cola.vaciar(sb, { online: true, userIdSesion: A });

    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('buena'));
    assert.equal(cola.fallidas.length, 1);
    assert.equal(cola.pendientes.length, 1);

    cola.descartarFallidas();
    assert.equal(cola.fallidas.length, 0);
    assert.equal(cola.pendientes.length, 1);
    assert.equal(cola.tareas[0].fila.client_id, 'buena');
});

// ------------------------------------------------------------
//  Aislamiento por usuario
// ------------------------------------------------------------
test('la cola de A no aparece al entrar como B', () => {
    const bruto = crearAlmacenFalso();
    const deA = montar(A, bruto);
    deA.cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));
    deA.cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c2'));

    const deB = montar(B, bruto);
    assert.equal(deB.cola.longitud, 0, 'B no ve nada de A');

    // Y la de A sigue intacta: no se ha perdido su trabajo.
    const deAOtraVez = montar(A, bruto);
    assert.equal(deAOtraVez.cola.longitud, 2);
});

test('la cola de A NO se envía con la sesión de B', async () => {
    const sb = crearSupabaseFalso();
    const bruto = crearAlmacenFalso();
    const deA = montar(A, bruto);
    deA.cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    // Aunque alguien intentara vaciar la cola de A teniendo la sesión de B.
    const r = await deA.cola.vaciar(sb, { online: true, userIdSesion: B });
    assert.equal(r.enviadas, 0);
    assert.equal(r.motivo, 'usuario-distinto');
    assert.equal(sb.tablas.expenses.length, 0);
});

test('una tarea con owner_user_id ajeno se rechaza aunque esté en la clave propia', async () => {
    const sb = crearSupabaseFalso();
    const bruto = crearAlmacenFalso();
    // Cola de A manipulada a mano con una tarea que dice ser de B.
    bruto.setItem(PREFIJO + '.' + A + '.cola', JSON.stringify([
        { tipo: TIPO.INSERTAR, tabla: 'expenses', fila: gasto('c1'), owner_user_id: B },
    ]));

    const { cola } = montar(A, bruto);
    assert.equal(cola.longitud, 0, 'se descarta al cargar');

    const r = await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(r.enviadas, 0);
    assert.equal(sb.tablas.expenses.length, 0);
});

test('al entrar con B se borran los datos locales de A', () => {
    const bruto = crearAlmacenFalso();
    const deA = crearAlmacen(A, bruto);
    deA.escribir('cache', { gastos: [1, 2, 3] });
    deA.escribir('cola', [{ tipo: 'insertar' }]);

    purgarOtrosUsuarios(B, bruto);

    assert.equal(bruto.getItem(PREFIJO + '.' + A + '.cache'), null);
    assert.equal(bruto.getItem(PREFIJO + '.' + A + '.cola'), null);
});

test('la migración desde el esquema antiguo adopta la cola y borra lo derivado', () => {
    const bruto = crearAlmacenFalso({
        'gastos.cola': JSON.stringify([{ tabla: 'expenses', fila: gasto('viejo') }]),
        'gastos.cache': JSON.stringify({ gastos: [] }),
        'gastos.grupo': '"g1"',
        'gastos.visita': '"2026-01-01"',
    });

    const r = migrarDesdeEsquemaAntiguo(A, bruto);

    assert.equal(r.adoptadas, 1);
    assert.deepEqual(r.descartadas.sort(), ['gastos.cache', 'gastos.cola', 'gastos.grupo', 'gastos.visita']);
    assert.equal(bruto.getItem('gastos.cola'), null);

    const { cola } = montar(A, bruto);
    assert.equal(cola.longitud, 1);
    assert.equal(cola.tareas[0].owner_user_id, A);
    assert.equal(cola.tareas[0].tipo, TIPO.INSERTAR);

    // Y no se vuelve a adoptar en el siguiente arranque.
    assert.equal(migrarDesdeEsquemaAntiguo(A, bruto).adoptadas, 0);
});

// ------------------------------------------------------------
//  Editar y borrar apuntes todavía pendientes
// ------------------------------------------------------------
test('editar un apunte aún sin enviar reescribe su alta, no encola un update', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1', { amount: 10 }));

    const modo = cola.editar('expenses', 'c1', { amount: 99 }, { clientId: 'c1' });

    assert.equal(modo, 'fusionado');
    assert.equal(cola.longitud, 1, 'sigue habiendo una sola tarea');
    assert.equal(cola.tareas[0].fila.amount, 99);

    await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(sb.tablas.expenses.length, 1);
    assert.equal(sb.tablas.expenses[0].amount, 99, 'llega el importe editado, no el original');
});

test('borrar un apunte aún sin enviar cancela su alta', async () => {
    const sb = crearSupabaseFalso();
    const { cola } = montar();
    cola.encolar(TIPO.INSERTAR, 'expenses', gasto('c1'));

    const modo = cola.borrar('expenses', 'c1', { clientId: 'c1' });

    assert.equal(modo, 'cancelado');
    assert.equal(cola.longitud, 0);

    await cola.vaciar(sb, { online: true, userIdSesion: A });
    assert.equal(sb.tablas.expenses.length, 0, 'nunca llegó a existir en el servidor');
});

// ------------------------------------------------------------
//  Update y delete que no afectan a ninguna fila
// ------------------------------------------------------------
test('un update que no cambia ninguna fila NO se da por bueno', async () => {
    const sb = crearSupabaseFalso();
    const r = await ejecutarTarea(sb, {
        tipo: TIPO.ACTUALIZAR, tabla: 'expenses', fila: { id: 'no-existe', amount: 5 },
    });
    assert.equal(r.ok, false);
    assert.equal(r.clase, CLASE.PERMISO);
});

test('un delete sobre algo que ya no está sí se da por bueno', async () => {
    const sb = crearSupabaseFalso();
    const r = await ejecutarTarea(sb, {
        tipo: TIPO.BORRAR, tabla: 'expenses', fila: { id: 'no-existe' },
    });
    assert.equal(r.ok, true);
    assert.equal(r.yaNoEstaba, true);
});
