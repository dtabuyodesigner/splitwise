// ============================================================
//  Construcción de la fila de un gasto
//
//  El fallo que cubren estas pruebas: la hoja validaba el grupo ACTIVO pero
//  escribía el grupo elegido en un <select>, así que se podía abrir desde un
//  grupo de dos y guardar en uno individual o de tres.
// ============================================================
import test from 'node:test';
import assert from 'node:assert/strict';

import { prepararFilaGasto, RECHAZO } from '../js/gastos.js';
import { TIPO } from '../js/miembros.js';

const YO = 'u-yo';
const OTRO = 'u-otro';
const AJENA = 'u-ajena';

const datos = {
    importe: 30,
    concepto: 'Cena',
    categoria: 'comer fuera',
    fecha: '2026-08-23',
};

const base = {
    grupoActivo: 'g-par',
    tipoGrupo: TIPO.PAR,
    miembros: [YO, OTRO],
    yoId: YO,
    formulario: { pagador: YO, reparto: 0.5 },
    datos,
};

// ------------------------------------------------------------
//  El grupo de destino no sale del formulario
// ------------------------------------------------------------
test('el grupo sale del grupo activo, no de ningún campo del formulario', () => {
    const r = prepararFilaGasto(base);
    assert.equal(r.ok, true);
    assert.equal(r.fila.group_id, 'g-par');
});

test('manipular un campo de grupo NO cambia el destino', () => {
    // Se cuelan campos con nombres plausibles: ninguno debe influir.
    const r = prepararFilaGasto({
        ...base,
        group_id: 'g-otro',
        entradaGrupo: 'g-otro',
        formulario: { ...base.formulario, group_id: 'g-otro', grupo: 'g-otro' },
        datos: { ...datos, group_id: 'g-otro', grupo: 'g-otro' },
    });
    assert.equal(r.ok, true);
    assert.equal(r.fila.group_id, 'g-par', 'la función solo mira grupoActivo');
});

test('al editar, el grupo del gasto manda sobre el grupo activo', () => {
    const r = prepararFilaGasto({
        ...base,
        grupoActivo: 'g-par',
        gastoExistente: { id: 'e1', group_id: 'g-original' },
        formulario: { pagador: YO, reparto: 0.5 },
        miembros: [YO, OTRO],
    });
    assert.equal(r.ok, true);
    assert.equal(r.fila.group_id, 'g-original', 'editar no mueve el gasto de grupo');
});

test('sin grupo de destino no se guarda nada', () => {
    assert.equal(prepararFilaGasto({ ...base, grupoActivo: null }).motivo, RECHAZO.SIN_GRUPO);
    assert.equal(prepararFilaGasto({ ...base, grupoActivo: '' }).motivo, RECHAZO.SIN_GRUPO);
});

// ------------------------------------------------------------
//  Qué admite cada tipo de grupo
// ------------------------------------------------------------
test('en un grupo SOLO se fuerza pagador = yo y reparto = 1 EN EL DATO', () => {
    const r = prepararFilaGasto({
        ...base,
        tipoGrupo: TIPO.SOLO,
        miembros: [YO],
        // La interfaz venía con un reparto a medias y un pagador ajeno:
        // exactamente lo que se colaría manipulando el formulario.
        formulario: { pagador: OTRO, reparto: 0.5 },
    });

    assert.equal(r.ok, true);
    assert.equal(r.fila.payer_share, 1, 'el 50 % manipulado no llega al dato');
    assert.equal(r.fila.paid_by, YO, 'el pagador ajeno no llega al dato');
});

test('un 50 % manipulado desde fuera no puede guardarse en un grupo SOLO', () => {
    for (const reparto of [0, 0.5, 0.7, 'libre', NaN, null, undefined]) {
        const r = prepararFilaGasto({
            ...base, tipoGrupo: TIPO.SOLO, miembros: [YO],
            formulario: { pagador: AJENA, reparto },
        });
        assert.equal(r.ok, true, 'reparto ' + reparto);
        assert.equal(r.fila.payer_share, 1);
        assert.equal(r.fila.paid_by, YO);
    }
});

test('en un grupo MULTI no se puede guardar', () => {
    const r = prepararFilaGasto({ ...base, tipoGrupo: TIPO.MULTI, miembros: [YO, OTRO, AJENA] });
    assert.equal(r.ok, false);
    assert.equal(r.motivo, RECHAZO.MULTI);
    assert.equal(r.fila, null);
    assert.match(r.mensaje, /más de dos participantes/i);
});

test('en un grupo AJENO no se puede guardar', () => {
    const r = prepararFilaGasto({ ...base, tipoGrupo: TIPO.AJENO, miembros: [OTRO, AJENA] });
    assert.equal(r.ok, false);
    assert.equal(r.motivo, RECHAZO.AJENO);
});

test('editar un gasto de un grupo que se ha vuelto MULTI también se rechaza', () => {
    const r = prepararFilaGasto({
        ...base,
        gastoExistente: { id: 'e1', group_id: 'g-trio' },
        tipoGrupo: TIPO.MULTI,
        miembros: [YO, OTRO, AJENA],
    });
    assert.equal(r.ok, false);
    assert.equal(r.motivo, RECHAZO.MULTI);
});

// ------------------------------------------------------------
//  Grupo de dos: pagador y reparto
// ------------------------------------------------------------
test('en un grupo PAR el pagador debe ser miembro', () => {
    const r = prepararFilaGasto({ ...base, formulario: { pagador: AJENA, reparto: 0.5 } });
    assert.equal(r.ok, false);
    assert.equal(r.motivo, RECHAZO.PAGADOR);
});

test('en un grupo PAR se admite a cualquiera de los dos miembros como pagador', () => {
    for (const quien of [YO, OTRO]) {
        const r = prepararFilaGasto({ ...base, formulario: { pagador: quien, reparto: 0.5 } });
        assert.equal(r.ok, true);
        assert.equal(r.fila.paid_by, quien);
    }
});

test('el reparto tiene que estar entre 0 y 1 y ser un número de verdad', () => {
    // null, undefined y '' NO pueden colarse como 0: `Number(null)` es 0, y 0
    // es un reparto válido que significa «el gasto es entero de la otra
    // persona». Un reparto ausente no puede convertirse en eso.
    for (const malo of [-0.1, 1.5, NaN, 'libre', null, undefined, '', '0.5']) {
        const r = prepararFilaGasto({ ...base, formulario: { pagador: YO, reparto: malo } });
        assert.equal(r.ok, false, 'reparto ' + malo);
        assert.equal(r.motivo, RECHAZO.REPARTO);
    }
    for (const bueno of [0, 0.5, 1, 0.3333]) {
        assert.equal(prepararFilaGasto({
            ...base, formulario: { pagador: YO, reparto: bueno },
        }).ok, true, 'reparto ' + bueno);
    }
});

// ------------------------------------------------------------
//  Datos básicos
// ------------------------------------------------------------
test('el importe tiene que ser mayor que cero', () => {
    for (const malo of [0, -5, NaN, null, 'mucho']) {
        assert.equal(prepararFilaGasto({ ...base, datos: { ...datos, importe: malo } }).motivo,
            RECHAZO.IMPORTE, 'importe ' + malo);
    }
});

test('el concepto no puede quedar vacío', () => {
    assert.equal(prepararFilaGasto({ ...base, datos: { ...datos, concepto: '   ' } }).motivo,
        RECHAZO.CONCEPTO);
});

test('el importe se redondea a céntimos en el dato guardado', () => {
    const r = prepararFilaGasto({ ...base, datos: { ...datos, importe: 10.005 } });
    assert.equal(r.fila.amount, 10.01);
});

// ------------------------------------------------------------
//  El flujo habitual no cambia
// ------------------------------------------------------------
test('el caso PAR de siempre sigue produciendo la misma fila', () => {
    const r = prepararFilaGasto(base);
    assert.deepEqual(r.fila, {
        group_id: 'g-par',
        paid_by: YO,
        amount: 30,
        description: 'Cena',
        category: 'comer fuera',
        payer_share: 0.5,
        spent_on: '2026-08-23',
    });
});

test('editar un gasto existente sigue funcionando', () => {
    const r = prepararFilaGasto({
        ...base,
        gastoExistente: { id: 'e1', group_id: 'g-par' },
        formulario: { pagador: OTRO, reparto: 1 },
        datos: { ...datos, importe: 42.5, concepto: 'Hotel', categoria: 'alojamiento' },
    });
    assert.equal(r.ok, true);
    assert.equal(r.fila.group_id, 'g-par');
    assert.equal(r.fila.paid_by, OTRO);
    assert.equal(r.fila.amount, 42.5);
    assert.equal(r.fila.payer_share, 1);
});
