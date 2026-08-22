// ============================================================
//  Pertenencia a grupos y aislamiento
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { otroDelGrupo, miembrosDeGrupo, gruposVisibles } from '../js/miembros.js';
import { escapar } from '../js/html.js';

const A = { id: 'a', display_name: 'Dani' };
const B = { id: 'b', display_name: 'Pilar' };
const C = { id: 'c', display_name: 'Alguien más' };

// ------------------------------------------------------------
//  Sin group_members (comportamiento heredado)
// ------------------------------------------------------------
test('con dos perfiles y sin membresías, la otra persona es la que queda', () => {
    const otro = otroDelGrupo('g1', { membresias: null, perfiles: [A, B], yoId: 'a' });
    assert.equal(otro.id, 'b');
});

test('con TRES perfiles y sin membresías no se elige un tercero al azar', () => {
    // El monolito hacía perfiles.find(p => p.id !== yo.id): devolvía el primero
    // que apareciera, y a partir de ahí los saldos eran incorrectos (R1).
    const otro = otroDelGrupo('g1', { membresias: null, perfiles: [A, B, C], yoId: 'a' });
    assert.equal(otro, null, 'sin certeza, no se inventa la otra persona');
});

// ------------------------------------------------------------
//  Con group_members
// ------------------------------------------------------------
const membresias = [
    { group_id: 'g1', user_id: 'a' },
    { group_id: 'g1', user_id: 'b' },
    { group_id: 'g2', user_id: 'a' },
    { group_id: 'g2', user_id: 'c' },
    { group_id: 'g3', user_id: 'b' },
    { group_id: 'g3', user_id: 'c' },
];

test('la otra persona depende del grupo, no de la instancia entera', () => {
    const perfiles = [A, B, C];
    assert.equal(otroDelGrupo('g1', { membresias, perfiles, yoId: 'a' }).id, 'b');
    assert.equal(otroDelGrupo('g2', { membresias, perfiles, yoId: 'a' }).id, 'c');
});

test('un grupo del que no eres miembro no tiene "otra persona" para ti', () => {
    assert.equal(otroDelGrupo('g3', { membresias, perfiles: [A, B, C], yoId: 'a' }), null);
});

test('un grupo con más de dos miembros no produce un saldo de par', () => {
    const tres = [...membresias, { group_id: 'g1', user_id: 'c' }];
    assert.equal(otroDelGrupo('g1', { membresias: tres, perfiles: [A, B, C], yoId: 'a' }), null);
});

test('miembrosDeGrupo devuelve solo los del grupo pedido', () => {
    assert.deepEqual(miembrosDeGrupo('g2', { membresias }).sort(), ['a', 'c']);
});

test('solo se listan los grupos de los que eres miembro', () => {
    const grupos = [{ id: 'g1' }, { id: 'g2' }, { id: 'g3' }];
    assert.deepEqual(gruposVisibles(grupos, { membresias, yoId: 'a' }).map((g) => g.id), ['g1', 'g2']);
    assert.deepEqual(gruposVisibles(grupos, { membresias, yoId: 'c' }).map((g) => g.id), ['g2', 'g3']);
});

test('sin membresías se ven todos los grupos que devuelva el servidor', () => {
    const grupos = [{ id: 'g1' }, { id: 'g2' }];
    assert.equal(gruposVisibles(grupos, { membresias: null, yoId: 'a' }).length, 2);
});

// ------------------------------------------------------------
//  Escapado
// ------------------------------------------------------------
test('escapar() también escapa las comillas', () => {
    // El monolito usaba div.textContent → innerHTML, que NO escapa comillas,
    // y el resultado se interpolaba dentro de atributos HTML (R8).
    assert.equal(escapar('a"b'), 'a&quot;b');
    assert.equal(escapar("a'b"), 'a&#39;b');
    assert.equal(escapar('<script>'), '&lt;script&gt;');
    assert.equal(escapar('a&b'), 'a&amp;b');
});

test('un color de perfil hostil no puede inyectar un atributo', () => {
    const hostil = 'laurel" onmouseover="robar()';
    const atributo = ' data-color="' + escapar(hostil) + '"';
    assert.ok(!atributo.includes('onmouseover="'), 'no se cierra el atributo');
    assert.ok(atributo.includes('&quot;'));
});

test('escapar() tolera null y undefined', () => {
    assert.equal(escapar(null), '');
    assert.equal(escapar(undefined), '');
    assert.equal(escapar(0), '0');
});
