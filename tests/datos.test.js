// ============================================================
//  Carga de datos: paginación completa y tolerancia a la migración
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { traerTodo, cargarTodo, crearGrupo } from '../js/supabase-data.js';
import { calcularSaldo } from '../js/balances.js';
import { crearSupabaseFalso } from './ayudas/supabase-falso.mjs';

const YO = 'u-yo';
const OTRO = 'u-otro';

function generar(n, plantilla) {
    return Array.from({ length: n }, (_, i) => ({ id: 'x' + i, ...plantilla(i) }));
}

test('traerTodo pagina hasta agotar la tabla', async () => {
    const sb = crearSupabaseFalso({
        expenses: generar(2600, () => ({ group_id: 'g1', amount: 1, paid_by: YO, payer_share: 0.5 })),
    });

    const r = await traerTodo(sb, 'expenses', { pagina: 1000 });

    assert.equal(r.filas.length, 2600, 'no se queda en el límite de 2500 del monolito');
    assert.equal(r.truncado, false);
    assert.equal(r.paginas, 3);
});

test('el saldo con más de 2500 gastos coincide con el de la tabla entera', async () => {
    // 3000 gastos míos de 10 € a medias → el otro me debe 15 000 €.
    const sb = crearSupabaseFalso({
        expenses: generar(3000, () => ({ group_id: 'g1', amount: 10, paid_by: YO, payer_share: 0.5 })),
        settlements: generar(700, (i) => ({
            group_id: 'g1', amount: 1, from_user: OTRO, to_user: YO, settled_on: '2026-01-01',
        })),
    });

    const datos = await cargarTodo(sb);

    assert.equal(datos.gastos.length, 3000);
    assert.equal(datos.liquidaciones.length, 700);
    assert.equal(datos.truncado, false);

    const saldo = calcularSaldo(datos.gastos, datos.liquidaciones, { yoId: YO, otroId: OTRO });
    assert.equal(saldo, 15000 - 700);

    // Y lo que habría dado el corte antiguo, para dejar constancia de la diferencia.
    const truncado = calcularSaldo(
        datos.gastos.slice(0, 2500), datos.liquidaciones.slice(0, 500), { yoId: YO, otroId: OTRO }
    );
    assert.equal(truncado, 12500 - 500);
    assert.notEqual(saldo, truncado);
});

test('al llegar al tope de seguridad se avisa en lugar de truncar en silencio', async () => {
    const sb = crearSupabaseFalso({
        expenses: generar(50, () => ({ group_id: 'g1', amount: 1, paid_by: YO, payer_share: 0.5 })),
    });

    const r = await traerTodo(sb, 'expenses', { pagina: 10, maxPaginas: 2 });

    assert.equal(r.filas.length, 20);
    assert.equal(r.truncado, true, 'la interfaz tiene que poder decirlo');
});

test('una página incompleta significa fin de tabla, aunque el servidor recorte', async () => {
    // Simula el max-rows de PostgREST: pide 1000, devuelve menos.
    const sb = crearSupabaseFalso({
        expenses: generar(700, () => ({ group_id: 'g1', amount: 1, paid_by: YO, payer_share: 0.5 })),
    });
    const r = await traerTodo(sb, 'expenses', { pagina: 1000 });
    assert.equal(r.filas.length, 700);
    assert.equal(r.truncado, false);
    assert.equal(r.paginas, 1);
});

test('cargarTodo funciona aunque group_members todavía no exista', async () => {
    const sb = crearSupabaseFalso({
        profiles: [{ id: YO }, { id: OTRO }],
        groups: [{ id: 'g1', name: 'Casa' }],
    });
    sb.inexistentes.add('group_members');

    const datos = await cargarTodo(sb);
    assert.equal(datos.membresias, null, 'null = "todavía no hay modelo de pertenencia"');
    assert.equal(datos.grupos.length, 1);
});

test('una tabla group_members vacía se trata como "todavía sin migrar"', async () => {
    // Ventana entre crear la tabla (0002) y ejecutar el backfill: si se
    // tomara [] como membresías reales, desaparecerían todos los grupos.
    const sb = crearSupabaseFalso({
        profiles: [{ id: YO }, { id: OTRO }],
        groups: [{ id: 'g1', name: 'Casa' }],
        group_members: [],
    });

    const datos = await cargarTodo(sb);
    assert.equal(datos.membresias, null);
    assert.equal(datos.grupos.length, 1);
});

test('cargarTodo devuelve las membresías cuando la tabla existe', async () => {
    const sb = crearSupabaseFalso({
        profiles: [{ id: YO }, { id: OTRO }],
        groups: [{ id: 'g1', name: 'Casa' }],
        group_members: [{ group_id: 'g1', user_id: YO, role: 'owner' }],
    });

    const datos = await cargarTodo(sb);
    assert.equal(datos.membresias.length, 1);
});

test('crear un grupo registra al creador como propietario', async () => {
    const sb = crearSupabaseFalso();
    const g = await crearGrupo(sb, 'Eslovenia 2026', YO);

    assert.equal(g.name, 'Eslovenia 2026');
    assert.equal(sb.tablas.group_members.length, 1);
    assert.equal(sb.tablas.group_members[0].user_id, YO);
    assert.equal(sb.tablas.group_members[0].role, 'owner');
});

test('crear un grupo funciona aunque group_members no exista todavía', async () => {
    const sb = crearSupabaseFalso();
    sb.fallar('group_members.insert', { code: '42P01', message: 'relation "group_members" does not exist' });

    const g = await crearGrupo(sb, 'Casa', YO);
    assert.equal(g.name, 'Casa');
    assert.equal(sb.tablas.groups.length, 1);
});
