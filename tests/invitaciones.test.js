import test from 'node:test';
import assert from 'node:assert/strict';

import { construirEnlaceInvitacion, leerTokenInvitacion } from '../js/invitaciones.js';

test('construye un enlace de invitacion sin perder el token', () => {
    const enlace = construirEnlaceInvitacion({
        origin: 'https://dani.example',
        pathname: '/splitwise/',
        token: 'A'.repeat(42) + '_',
    });

    assert.equal(enlace, 'https://dani.example/splitwise/?invitacion=' + 'A'.repeat(42) + '_');
});

test('lee solo tokens con el formato de invitacion', () => {
    assert.equal(leerTokenInvitacion('?invitacion=' + 'A'.repeat(43)), 'A'.repeat(43));
    assert.equal(leerTokenInvitacion('?invitacion=corto'), null);
    assert.equal(leerTokenInvitacion('?otro=valor'), null);
});
