// ============================================================
//  Traslado de saldo · módulo puro, cola y mutaciones
//
//  Lo que se persigue aquí es lo mismo que en el SQL, pero del lado del
//  navegador: que no se ofrezca un destino imposible, que no se envíe un
//  importe mayor que la deuda, y sobre todo que un doble clic o un reintento
//  NO puedan trasladar dos veces.
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import {
    ROL, argumentosDeTraslado, destinosValidos, deudaDelGrupo,
    esMovimientoDeTraslado, resumenDeTraslado, tituloDeTraslado, validarTraslado,
} from '../js/traslados.js';
import { ColaOffline, TIPO, ejecutarTarea } from '../js/offline-queue.js';
import { trasladarSaldo } from '../js/mutaciones.js';

const YO = 'u-yo';
const OTRO = 'u-otro';
const TERCERO = 'u-tercero';

const G = { slovenia: 'g-slo', bierzo: 'g-bie', casa: 'g-casa', solo: 'g-solo', trio: 'g-trio' };

const membresias = [
    { group_id: G.slovenia, user_id: YO, role: 'owner' },
    { group_id: G.slovenia, user_id: OTRO, role: 'owner' },
    { group_id: G.bierzo, user_id: YO, role: 'owner' },
    { group_id: G.bierzo, user_id: OTRO, role: 'owner' },
    { group_id: G.casa, user_id: YO, role: 'owner' },
    { group_id: G.casa, user_id: OTRO, role: 'owner' },
    { group_id: G.solo, user_id: YO, role: 'owner' },
    { group_id: G.trio, user_id: YO, role: 'owner' },
    { group_id: G.trio, user_id: OTRO, role: 'owner' },
    { group_id: G.trio, user_id: TERCERO, role: 'member' },
];

const grupos = [
    { id: G.slovenia, name: 'Slovenia' }, { id: G.bierzo, name: 'Bierzo & Asturias' },
    { id: G.casa, name: 'Casa' }, { id: G.solo, name: 'Individual' }, { id: G.trio, name: 'Trío' },
];

// En Slovenia YO debo 225,59 €: lo pagó OTRO y va a medias.
const gastos = [
    { group_id: G.slovenia, paid_by: OTRO, amount: 451.18, payer_share: 0.5 },
    { group_id: G.trio, paid_by: OTRO, amount: 100, payer_share: 0.5 },
];
const liquidaciones = [];

const perfiles = [
    { id: YO, display_name: 'Dani', color: 'laurel' },
    { id: OTRO, display_name: 'Pilar', color: 'buganvilla' },
    { id: TERCERO, display_name: 'Otra', color: 'laurel' },
];

const contexto = { gastos, liquidaciones, membresias, perfiles, yoId: YO };

test('deudaDelGrupo identifica deudor y acreedor, no solo el signo', () => {
    const d = deudaDelGrupo(G.slovenia, contexto);
    assert.equal(d.euros, 225.59);
    assert.equal(d.deudor, YO, 'lo pagó el otro, así que el deudor soy yo');
    assert.equal(d.acreedor, OTRO);
});

test('deudaDelGrupo devuelve null si el grupo está saldado', () => {
    assert.equal(deudaDelGrupo(G.casa, contexto), null);
});

test('deudaDelGrupo devuelve null en un grupo SOLO y en uno MULTI', () => {
    assert.equal(deudaDelGrupo(G.solo, contexto), null, 'un grupo de una persona no tiene deuda entre dos');
    assert.equal(deudaDelGrupo(G.trio, contexto), null, 'con tres el reparto no está implementado');
});

test('destinosValidos solo ofrece grupos con las MISMAS dos personas', () => {
    const d = destinosValidos(G.slovenia, { membresias, perfiles, yoId: YO, grupos }).map((g) => g.id);
    assert.deepEqual(d.sort(), [G.bierzo, G.casa].sort());
    assert.ok(!d.includes(G.slovenia), 'nunca se ofrece el propio origen');
    assert.ok(!d.includes(G.solo), 'ni un grupo de una sola persona');
    assert.ok(!d.includes(G.trio), 'ni uno con un tercero dentro');
});

test('destinosValidos no ofrece nada desde un grupo que no es PAR', () => {
    assert.deepEqual(destinosValidos(G.trio, { membresias, perfiles, yoId: YO, grupos }), []);
    assert.deepEqual(destinosValidos(G.solo, { membresias, perfiles, yoId: YO, grupos }), []);
});

test('validarTraslado rechaza lo que el servidor también rechazaría', () => {
    const deuda = deudaDelGrupo(G.slovenia, contexto);
    const base = { origenId: G.slovenia, destinoId: G.bierzo, deuda };

    assert.equal(validarTraslado({ ...base, destinoId: G.slovenia }).ok, false, 'destino igual al origen');
    assert.equal(validarTraslado({ ...base, destinoId: null }).ok, false, 'sin destino');
    assert.equal(validarTraslado({ ...base, importe: 0 }).ok, false, 'cero');
    assert.equal(validarTraslado({ ...base, importe: -5 }).ok, false, 'negativo');
    assert.equal(validarTraslado({ ...base, importe: 'hola' }).ok, false, 'no numérico');
    assert.equal(validarTraslado({ ...base, deuda: null }).ok, false, 'sin deuda');
});

test('validarTraslado corta en el límite exacto, no un céntimo más', () => {
    const deuda = deudaDelGrupo(G.slovenia, contexto);
    const base = { origenId: G.slovenia, destinoId: G.bierzo, deuda };

    assert.equal(validarTraslado({ ...base, importe: 225.59 }).ok, true, 'la deuda entera vale');
    assert.equal(validarTraslado({ ...base, importe: 225.60 }).ok, false, 'un céntimo más, no');
});

test('validarTraslado trata la deuda entera como traslado total', () => {
    const deuda = deudaDelGrupo(G.slovenia, contexto);
    const r = validarTraslado({ origenId: G.slovenia, destinoId: G.bierzo, importe: 225.59, deuda });
    assert.equal(r.importe, null, 'pedir justo la deuda es «todo»: lo calcula el servidor');
});

test('validarTraslado acepta coma decimal, que es lo que se teclea aquí', () => {
    const deuda = deudaDelGrupo(G.slovenia, contexto);
    const r = validarTraslado({ origenId: G.slovenia, destinoId: G.bierzo, importe: '20,50', deuda });
    assert.equal(r.ok, true);
    assert.equal(r.importe, 20.5);
});

test('validarTraslado no se confunde con la aritmética binaria', () => {
    const deuda = { euros: 0.3, deudor: YO, acreedor: OTRO };
    const r = validarTraslado({ origenId: G.slovenia, destinoId: G.bierzo, importe: 0.1 + 0.2, deuda });
    assert.equal(r.ok, true, '0.1+0.2 es 0.30000000000000004 y aun así cabe en 0,30 €');
});

test('un movimiento de traslado no se confunde con un pago', () => {
    assert.equal(esMovimientoDeTraslado({ transfer_id: 't1', transfer_role: ROL.ORIGEN }), true);
    assert.equal(esMovimientoDeTraslado({ id: 'x' }), false);
    assert.equal(esMovimientoDeTraslado(null), false);
});

test('el título dice la verdad en cada punta del traslado', () => {
    const o = tituloDeTraslado({ transfer_role: ROL.ORIGEN }, { nombreDestino: 'Bierzo' });
    const d = tituloDeTraslado({ transfer_role: ROL.DESTINO }, { nombreOrigen: 'Slovenia' });
    assert.match(o, /trasladado a Bierzo/);
    assert.match(d, /procedente de Slovenia/);
    assert.notEqual(o, d, 'en el destino la deuda se crea, no se salda');
    assert.match(tituloDeTraslado({ transfer_role: ROL.REVERSION_ORIGEN }), /deshecho/);
});

test('el resumen dice cuánto queda tras un traslado parcial', () => {
    const deuda = deudaDelGrupo(G.slovenia, contexto);
    const r = resumenDeTraslado({
        deuda, importe: 25.59, nombreOrigen: 'Slovenia', nombreDestino: 'Bierzo',
        nombre: (id) => (id === YO ? 'Dani' : 'Pilar'),
    });
    assert.equal(r.cuanto, 25.59);
    assert.equal(r.restante, 200);
    assert.equal(r.total, false);
    assert.equal(r.deudor, 'Dani');
});

// ── La idempotencia, que es lo que impide trasladar dos veces ──

function almacenFalso() {
    const datos = new Map();
    return {
        leer: (nombre, porDefecto = null) => (datos.has(nombre) ? datos.get(nombre) : porDefecto),
        escribir: (nombre, valor) => { datos.set(nombre, valor); },
    };
}

test('un doble clic no encola dos traslados', () => {
    const cola = new ColaOffline({ almacen: almacenFalso(), userId: YO });
    const args = argumentosDeTraslado({
        origenId: G.slovenia, destinoId: G.bierzo, importe: null, clave: 'k-1',
    });

    assert.equal(cola.encolarLlamada('trasladar_saldo', args), true);
    assert.equal(cola.encolarLlamada('trasladar_saldo', args), false, 'la segunda no entra');
    assert.equal(cola.tareas.length, 1);
});

test('dos traslados distintos SÍ se encolan los dos', () => {
    const cola = new ColaOffline({ almacen: almacenFalso(), userId: YO });
    cola.encolarLlamada('trasladar_saldo', argumentosDeTraslado({
        origenId: G.slovenia, destinoId: G.bierzo, importe: null, clave: 'k-1',
    }));
    cola.encolarLlamada('trasladar_saldo', argumentosDeTraslado({
        origenId: G.casa, destinoId: G.bierzo, importe: null, clave: 'k-2',
    }));
    assert.equal(cola.tareas.length, 2, 'la clave distingue, no el destino');
});

test('la clave viaja dentro de los argumentos y no cambia al reintentar', () => {
    const args = argumentosDeTraslado({
        origenId: G.slovenia, destinoId: G.bierzo, importe: 20, clave: 'k-fija',
    });
    assert.equal(args.p_idempotency_key, 'k-fija');
    assert.equal(args.p_importe, 20);
    assert.equal(argumentosDeTraslado({
        origenId: G.slovenia, destinoId: G.bierzo, importe: null, clave: 'k-fija',
    }).p_importe, null, 'null significa «todo»');
});

test('ejecutarTarea llama a la función con sus argumentos', async () => {
    const llamadas = [];
    const sb = { rpc: async (fn, args) => { llamadas.push([fn, args]); return { data: { id: 't1' } }; } };
    const r = await ejecutarTarea(sb, {
        tipo: TIPO.LLAMAR, tabla: 'trasladar_saldo',
        fila: { p_idempotency_key: 'k-1' },
    });
    assert.equal(r.ok, true);
    assert.deepEqual(llamadas, [['trasladar_saldo', { p_idempotency_key: 'k-1' }]]);
});

test('un choque de clave se toma como tarea cumplida, no como fallo', async () => {
    const sb = {
        rpc: async () => ({ error: { code: '23505', message: 'duplicate key value' } }),
    };
    const r = await ejecutarTarea(sb, {
        tipo: TIPO.LLAMAR, tabla: 'trasladar_saldo', fila: { p_idempotency_key: 'k-1' },
    });
    assert.equal(r.ok, true, 'la clave ya estaba: el traslado entró antes');
    assert.equal(r.duplicado, true);
});

test('sin conexión el traslado va a la cola, no se pierde', async () => {
    const cola = new ColaOffline({ almacen: almacenFalso(), userId: YO });
    const args = argumentosDeTraslado({
        origenId: G.slovenia, destinoId: G.bierzo, importe: null, clave: 'k-off',
    });
    const r = await trasladarSaldo({}, { argumentos: args, cola, online: false });
    assert.equal(r.estado, 'pendiente');
    assert.equal(cola.tareas.length, 1);
});

test('un fallo de RED encola; uno de permiso NO', async () => {
    const cola = new ColaOffline({ almacen: almacenFalso(), userId: YO });
    const args = (k) => argumentosDeTraslado({
        origenId: G.slovenia, destinoId: G.bierzo, importe: null, clave: k,
    });

    const red = { rpc: async () => { throw new TypeError('Failed to fetch'); } };
    const r1 = await trasladarSaldo(red, { argumentos: args('k-red'), cola, online: true });
    assert.equal(r1.estado, 'pendiente');
    assert.equal(cola.tareas.length, 1);

    const permiso = {
        rpc: async () => ({ error: { code: '42501', message: 'permission denied' } }),
    };
    const r2 = await trasladarSaldo(permiso, { argumentos: args('k-perm'), cola, online: true });
    assert.notEqual(r2.estado, 'pendiente', 'reintentar un permiso denegado no arregla nada');
    assert.equal(cola.tareas.length, 1, 'y no se encola');
});

test('reintentar la misma tarea dos veces usa la misma clave', async () => {
    const claves = [];
    const sb = { rpc: async (_fn, args) => { claves.push(args.p_idempotency_key); return { data: {} }; } };
    const tarea = {
        tipo: TIPO.LLAMAR, tabla: 'trasladar_saldo',
        fila: { p_idempotency_key: 'k-estable' },
    };
    await ejecutarTarea(sb, tarea);
    await ejecutarTarea(sb, tarea);
    assert.deepEqual(claves, ['k-estable', 'k-estable'], 'la clave nunca se regenera');
});
