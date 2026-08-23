// ============================================================
//  Capa de interfaz
//  Todo lo que toca el DOM. La lógica que se puede probar vive en los
//  módulos que importa este archivo.
// ============================================================
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

import {
    SUPABASE_URL, SUPABASE_ANON_KEY, VERSION_APP, GOOGLE_ACTIVO, TOPE_FIEL,
    CATEGORIES, CATEGORY_META,
} from './config.js';
import { formatoDinero, aNumero } from './dinero.js';
import { hoyISO, tituloDia } from './fechas.js';
import { escapar } from './html.js';
import { CLASE, traducirError, mensajeResultado } from './errores.js';
import { calcularSaldo, delGrupo, totalesDelGrupo, sumar, porCategoria } from './balances.js';
import {
    otroDelGrupo, gruposVisibles, tipoDeGrupo, perfilesDelGrupo, avisoDeTipo,
    TIPO as TIPO_GRUPO, MODO, modoDe,
} from './miembros.js';
import {
    crearAlmacen, purgarOtrosUsuarios, migrarDesdeEsquemaAntiguo, CLAVE_CORREO,
} from './almacen.js';
import { ColaOffline, TIPO } from './offline-queue.js';
import { cargarTodo, crearGrupo as crearGrupoRemoto } from './supabase-data.js';
import { crearApunte, editarApunte, borrarApunte } from './mutaciones.js';
import { prepararFilaGasto } from './gastos.js';
import { analizarCSV, construirCSV } from './csv.js';
import { interpretarDictado } from './voice.js';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

// ------------------------------------------------------------
//  Estado
// ------------------------------------------------------------
const estado = {
    sesion: null,
    yo: null,
    otro: null,
    perfiles: [],
    grupos: [],
    membresias: null,
    tipoGrupo: 'ninguno',
    miembros: [],
    grupoActivo: null,
    gastos: [],
    liquidaciones: [],
    almacen: null,
    cola: null,
    truncado: false,
    editando: null,
    /** Grupo al que escribe cada hoja abierta. Se fija al abrirla y no cambia. */
    grupoHoja: null,
    grupoHojaLiquidar: null,
    grupoHojaImportar: null,
    editandoLiquidacion: null,
    desdeVisita: null,
    novedadesVistas: false,
    sesionCaducada: false,
    formulario: { pagador: null, reparto: 0.5, repartoLibre: 50 },
    filtro: { texto: '', personaId: null, categoria: null },
    modoAlta: false,
};

const $ = (id) => document.getElementById(id);

const online = () => navigator.onLine;
const miId = () => estado.sesion?.user?.id || null;

// ------------------------------------------------------------
//  Avisos
// ------------------------------------------------------------
let recadoTemporizador = null;

function recado(texto) {
    document.querySelectorAll('.recado').forEach((n) => n.remove());
    const n = document.createElement('div');
    n.className = 'recado';
    n.setAttribute('role', 'status');
    n.textContent = texto;
    document.body.appendChild(n);
    clearTimeout(recadoTemporizador);
    recadoTemporizador = setTimeout(() => n.remove(), 2800);
}

function mostrarAviso(elemento, texto) {
    if (!elemento) return;
    if (!texto) {
        elemento.classList.add('oculto');
        elemento.textContent = '';
        return;
    }
    elemento.textContent = texto;
    elemento.classList.remove('oculto');
}

/**
 * Da cuenta del resultado real de una escritura. Distingue las cuatro
 * situaciones que exige el encargo en lugar de decir siempre "guardado
 * localmente" (riesgo R2).
 */
function informar(resultado, { sustantivo = 'Gasto', aviso = null, exito = null } = {}) {
    if (resultado.estado === 'sesion') {
        estado.sesionCaducada = true;
        pintarEstado();
    }
    if (resultado.estado === 'error' || resultado.estado === 'sesion') {
        mostrarAviso(aviso, mensajeResultado(resultado, { sustantivo }));
        recado(resultado.estado === 'sesion' ? 'Sesión caducada' : 'No se ha guardado');
        return false;
    }
    if (exito && (resultado.estado === 'servidor' || resultado.estado === 'duplicado')) {
        recado(exito);
    } else {
        recado(mensajeResultado(resultado, { sustantivo }));
    }
    return true;
}

// ------------------------------------------------------------
//  Copia local
// ------------------------------------------------------------
function guardarCache() {
    if (!estado.almacen) return;
    estado.almacen.escribir('cache', {
        perfiles: estado.perfiles,
        grupos: estado.grupos,
        membresias: estado.membresias,
        gastos: estado.gastos.filter((g) => !g.pendiente),
        liquidaciones: estado.liquidaciones.filter((l) => !l.pendiente),
    });
}

function leerCache() {
    if (!estado.almacen) return false;
    const datos = estado.almacen.leer('cache', null);
    if (!datos) return false;
    estado.perfiles = datos.perfiles || [];
    estado.grupos = datos.grupos || [];
    estado.membresias = datos.membresias ?? null;
    estado.gastos = datos.gastos || [];
    estado.liquidaciones = datos.liquidaciones || [];
    repartirPerfiles();
    elegirGrupoInicial();
    return true;
}

// ------------------------------------------------------------
//  Sesión
// ------------------------------------------------------------
function pintarModoAcceso() {
    $('campoNombre').classList.toggle('oculto', !estado.modoAlta);
    $('botonAcceder').textContent = estado.modoAlta ? 'Crear cuenta' : 'Entrar';
    $('botonCambiarModo').textContent = estado.modoAlta
        ? 'Ya tengo cuenta, entrar'
        : 'Crear una cuenta';
    $('entradaClave').setAttribute(
        'autocomplete',
        estado.modoAlta ? 'new-password' : 'current-password'
    );
    mostrarAviso($('avisoAcceso'), '');
}

async function accederConGoogle() {
    if (!online()) {
        mostrarAviso($('avisoAcceso'), 'Para entrar hace falta conexión.');
        return;
    }
    try {
        const destino = window.location.href.split('#')[0].split('?')[0];
        const { error } = await sb.auth.signInWithOAuth({
            provider: 'google',
            options: { redirectTo: destino },
        });
        if (error) throw error;
    } catch (error) {
        mostrarAviso($('avisoAcceso'), traducirError(error));
    }
}

async function acceder() {
    const correo = $('entradaCorreo').value.trim();
    const clave = $('entradaClave').value;
    const nombre = $('entradaNombre').value.trim();

    if (!correo || !clave) {
        mostrarAviso($('avisoAcceso'), 'Faltan el correo o la contraseña.');
        return;
    }
    if (estado.modoAlta && !nombre) {
        mostrarAviso($('avisoAcceso'), 'Escribe el nombre que quieres que aparezca en la app.');
        return;
    }
    if (!online()) {
        mostrarAviso($('avisoAcceso'), 'Para entrar la primera vez hace falta conexión.');
        return;
    }

    $('botonAcceder').disabled = true;
    mostrarAviso($('avisoAcceso'), '');

    try {
        if (estado.modoAlta) {
            const { error } = await sb.auth.signUp({
                email: correo,
                password: clave,
                options: { data: { display_name: nombre } },
            });
            if (error) throw error;
            recado('Cuenta creada');
        } else {
            const { error } = await sb.auth.signInWithPassword({ email: correo, password: clave });
            if (error) throw error;
        }
        try { localStorage.setItem(CLAVE_CORREO, correo); } catch { /* sin almacenamiento */ }
    } catch (error) {
        mostrarAviso($('avisoAcceso'), traducirError(error));
    } finally {
        $('botonAcceder').disabled = false;
    }
}

async function salir() {
    const pendientes = estado.cola ? estado.cola.pendientes.length : 0;
    if (pendientes && !confirm(
        'Tienes ' + pendientes + ' apunte(s) sin enviar. Se guardarán en este dispositivo ' +
        'y se enviarán cuando vuelvas a entrar con esta misma cuenta. ¿Cerrar sesión?'
    )) return;

    // La caché se borra siempre; la cola se conserva bajo la clave del propio
    // usuario, así que otra cuenta no puede verla ni enviarla (riesgo R3).
    if (estado.almacen) {
        estado.almacen.borrar('cache');
        estado.almacen.borrar('visita');
    }

    desconectarRealtime();
    await sb.auth.signOut();
    location.reload();
}

// ------------------------------------------------------------
//  Datos
// ------------------------------------------------------------
function repartirPerfiles() {
    const id = miId();
    estado.yo = id ? (estado.perfiles.find((p) => p.id === id) || null) : null;

    const ctx = {
        membresias: estado.membresias,
        perfiles: estado.perfiles,
        yoId: estado.yo?.id,
    };

    estado.tipoGrupo = tipoDeGrupo(estado.grupoActivo, ctx);
    estado.miembros = perfilesDelGrupo(estado.grupoActivo, ctx);
    // `otro` solo existe cuando el grupo es exactamente un par. En un grupo
    // individual o de tres o más es null a propósito: elegir una "otra
    // persona" arbitraria es lo que producía saldos incorrectos.
    estado.otro = otroDelGrupo(estado.grupoActivo, ctx);
}

/**
 * Comprueba que el grupo activo admite la acción y, si no, lo explica.
 * @returns {boolean} true si se puede seguir.
 */
function grupoAdmite(accion, grupoId = estado.grupoActivo) {
    const tipo = grupoId === estado.grupoActivo ? estado.tipoGrupo : tipoDe(grupoId);
    if (tipo === TIPO_GRUPO.MULTI) {
        recado(accion === 'saldar'
            ? 'Saldar cuentas todavía no está disponible en grupos de más de dos personas'
            : 'Este grupo tiene más de dos participantes; el reparto múltiple todavía no está disponible');
        return false;
    }
    if (tipo === TIPO_GRUPO.AJENO) {
        recado('No perteneces a este grupo');
        return false;
    }
    if (tipo === TIPO_GRUPO.SOLO && accion !== 'gasto') {
        recado(accion === 'saldar'
            ? 'En un grupo individual no hay nada que saldar'
            : 'Invita a alguien al grupo antes de importar gastos compartidos');
        return false;
    }
    return true;
}

/** Contexto de pertenencia, para clasificar cualquier grupo, no solo el activo. */
function ctxPertenencia() {
    return {
        membresias: estado.membresias,
        perfiles: estado.perfiles,
        yoId: estado.yo?.id,
    };
}

/** Tipo de un grupo concreto, resuelto en el momento. */
function tipoDe(grupoId) {
    return tipoDeGrupo(grupoId, ctxPertenencia());
}

/** Ids de los miembros de un grupo concreto. */
function miembrosDe(grupoId) {
    return perfilesDelGrupo(grupoId, ctxPertenencia()).map((p) => p.id);
}

/** ¿Se puede calcular y enseñar un saldo en el grupo activo? */
function hayReparto() {
    return estado.tipoGrupo === TIPO_GRUPO.PAR;
}

/** Personas del grupo activo, para pintar chips, opciones y desgloses. */
function genteDelGrupo() {
    if (estado.miembros?.length) return estado.miembros;
    return [estado.yo, estado.otro].filter(Boolean);
}

function perfil(id) {
    return estado.perfiles.find((p) => p.id === id) || { display_name: 'Alguien', color: 'laurel' };
}

/** El otro miembro del par, para el reparto de un gasto concreto. */
function otroId(id) {
    if (!estado.yo || !estado.otro) return null;
    return id === estado.yo.id ? estado.otro.id : estado.yo.id;
}

function grupo(id) {
    return misGrupos().find((g) => String(g.id) === String(id));
}

function misGrupos() {
    return gruposVisibles(estado.grupos, {
        membresias: estado.membresias,
        yoId: estado.yo?.id,
    });
}

function elegirGrupoInicial() {
    const guardado = estado.almacen ? estado.almacen.leer('grupo', null) : null;
    if (guardado && grupo(guardado)) {
        estado.grupoActivo = guardado;
        repartirPerfiles();
        return;
    }
    estado.grupoActivo = misGrupos()[0]?.id || null;
    repartirPerfiles();
}

function fijarGrupo(id) {
    estado.grupoActivo = id;
    if (estado.almacen) estado.almacen.escribir('grupo', id);
    repartirPerfiles();
    escucharCambios();
    pintar();
}

const gastosDelGrupo = () => delGrupo(estado.gastos, estado.grupoActivo);
const liquidacionesDelGrupo = () => delGrupo(estado.liquidaciones, estado.grupoActivo);

async function traerDatos() {
    const datos = await cargarTodo(sb, { online: online() });

    estado.perfiles = datos.perfiles;
    estado.grupos = datos.grupos;
    estado.membresias = datos.membresias;
    estado.gastos = datos.gastos;
    estado.liquidaciones = datos.liquidaciones;
    estado.truncado = datos.truncado;

    repartirPerfiles();
    if (!grupo(estado.grupoActivo)) elegirGrupoInicial();
    repartirPerfiles();
    reponerPendientes();
    guardarCache();
}

/** Vuelve a poner en pantalla los apuntes que siguen en la cola sin enviar. */
function reponerPendientes() {
    if (!estado.cola) return;
    for (const tarea of estado.cola.tareas) {
        if (tarea.tipo !== TIPO.INSERTAR) continue;
        const lista = tarea.tabla === 'expenses' ? estado.gastos : estado.liquidaciones;
        const cid = tarea.fila?.client_id;
        if (cid && !lista.some((f) => f.client_id === cid)) {
            lista.push({ ...tarea.fila, id: cid, pendiente: true, fallo: tarea.fallo || null });
        }
    }
}

async function refrescar() {
    if (!online()) {
        pintar();
        return;
    }
    try {
        await traerDatos();
        estado.sesionCaducada = false;
    } catch (e) {
        const clase = e?.clasificacion?.clase;
        if (clase === CLASE.SESION) estado.sesionCaducada = true;
        console.warn('No se han podido traer los datos', e);
    }
    pintar();
}

async function sincronizar() {
    if (!estado.cola) return;
    const r = await estado.cola.vaciar(sb, { online: online(), userIdSesion: miId() });

    if (r.sesionCaducada) {
        estado.sesionCaducada = true;
        pintarEstado();
        return;
    }
    if (r.rechazadas?.length) {
        recado(r.rechazadas.length === 1
            ? 'Un apunte no se ha podido enviar'
            : r.rechazadas.length + ' apuntes no se han podido enviar');
    }
    if (r.enviadas > 0) {
        recado(r.enviadas === 1 ? 'Apunte sincronizado' : r.enviadas + ' apuntes sincronizados');
        await refrescar();
    } else {
        pintarEstado();
    }
}

// ------------------------------------------------------------
//  Saldo
// ------------------------------------------------------------
function saldoActual() {
    return calcularSaldo(gastosDelGrupo(), liquidacionesDelGrupo(), {
        yoId: estado.yo?.id,
        otroId: estado.otro?.id,
    });
}

// ------------------------------------------------------------
//  Pintado
// ------------------------------------------------------------
function pintar() {
    pintarGrupos();
    pintarSaldo();
    pintarTotales();
    pintarFiltros();
    pintarLista();
    pintarEstado();
    pintarNovedades();
    const tieneGrupo = Boolean(grupo(estado.grupoActivo));
    $('utiles').classList.toggle('oculto', !tieneGrupo);
    $('cajaFiltro').classList.toggle('oculto', !tieneGrupo || !gastosDelGrupo().length);
}

function pintarGrupos() {
    const caja = $('grupos');
    caja.innerHTML = '';

    for (const g of misGrupos()) {
        const b = document.createElement('button');
        b.className = 'grupo';
        b.textContent = g.name;
        b.setAttribute('aria-current', String(String(g.id) === String(estado.grupoActivo)));
        b.addEventListener('click', () => fijarGrupo(g.id));
        caja.appendChild(b);
    }

    const gestion = document.createElement('button');
    gestion.className = 'grupo grupo--gestion';
    gestion.textContent = misGrupos().length ? '+ Grupo' : '+ Crear grupo';
    gestion.addEventListener('click', abrirHojaGrupos);
    caja.appendChild(gestion);

    const activo = caja.querySelector('[aria-current="true"]');
    if (activo) activo.scrollIntoView({ block: 'nearest', inline: 'center' });
}

function colorDe(p) {
    return p?.color === 'buganvilla' ? '#D98CA8' : '#7FC8B4';
}

function pintarSaldo() {
    const saldo = saldoActual();
    const cifra = $('saldoCifra');
    const frase = $('saldoFrase');
    const barra = $('fielBarra');
    const g = grupo(estado.grupoActivo);

    $('saldoRotulo').textContent = g ? 'Saldo · ' + g.name : 'Saldo';

    const nombreOtro = estado.otro?.display_name;
    const cuantos = estado.miembros?.length || 0;

    $('fielIzquierda').textContent = estado.yo?.display_name || '—';
    $('fielDerecha').textContent = nombreOtro
        || (estado.tipoGrupo === TIPO_GRUPO.MULTI ? cuantos + ' participantes' : '—');

    const enBlanco = (texto) => {
        frase.innerHTML = texto;
        cifra.textContent = '';
        cifra.style.color = '';
        barra.style.width = '0';
    };

    if (!g) return enBlanco('Crea un grupo para empezar a apuntar gastos.');
    if (!estado.yo) return enBlanco('Tu perfil todavía no está creado en la base de datos.');

    // Grupo individual: es válido y funciona. No hay reparto que enseñar.
    if (estado.tipoGrupo === TIPO_GRUPO.SOLO) {
        return enBlanco(
            'Grupo individual. Aquí solo apuntas lo tuyo, así que no hay nada que repartir. ' +
            'Invita a alguien cuando quieras compartirlo.'
        );
    }

    // Tres o más: NO se calcula saldo. Enseñar uno contra "la otra persona"
    // sería enseñar una cifra incorrecta.
    if (estado.tipoGrupo === TIPO_GRUPO.MULTI) {
        return enBlanco(
            '<strong>Este grupo tiene más de dos participantes; el reparto múltiple ' +
            'todavía no está disponible.</strong> Puedes seguir consultando los gastos ' +
            'y los totales, pero el saldo no se calcula.'
        );
    }

    if (estado.tipoGrupo === TIPO_GRUPO.AJENO) {
        return enBlanco('No perteneces a este grupo.');
    }

    if (saldo === null) {
        return enBlanco('Cuando la otra persona acepte la invitación, aquí aparecerá el reparto.');
    }

    cifra.textContent = formatoDinero(Math.abs(saldo));

    if (Math.abs(saldo) < 0.005) {
        frase.innerHTML = 'Estáis en paz. Nadie debe nada.';
        cifra.style.color = '';
        barra.style.width = '0';
        barra.style.left = '50%';
        return;
    }

    if (saldo > 0) {
        frase.innerHTML = '<strong>' + escapar(nombreOtro) + '</strong> te debe esta cantidad.';
        cifra.style.color = colorDe(estado.yo);
        barra.style.background = colorDe(estado.yo);
        barra.style.left = 'auto';
        barra.style.right = '50%';
    } else {
        frase.innerHTML = 'Le debes esta cantidad a <strong>' + escapar(nombreOtro) + '</strong>.';
        cifra.style.color = colorDe(estado.otro);
        barra.style.background = colorDe(estado.otro);
        barra.style.right = 'auto';
        barra.style.left = '50%';
    }

    barra.style.width = (Math.min(Math.abs(saldo) / TOPE_FIEL, 1) * 50) + '%';
}

function pintarTotales() {
    const caja = $('totales');

    if (!grupo(estado.grupoActivo) || (!gastosDelGrupo().length && !liquidacionesDelGrupo().length)) {
        caja.classList.add('oculto');
        return;
    }

    const { total, adelantado } = totalesDelGrupo(gastosDelGrupo(), estado.perfiles);

    $('totalGrupo').textContent = formatoDinero(total);
    $('totalMio').textContent = formatoDinero(adelantado[estado.yo?.id] || 0);
    $('totalMio').style.color = colorDe(estado.yo);
    $('totalMioRotulo').textContent = 'Has pagado';

    const saldo = saldoActual();
    if (hayReparto() && saldo !== null) {
        $('totalSuyo').textContent = formatoDinero(Math.abs(saldo));
        $('totalSuyoRotulo').textContent =
            Math.abs(saldo) < 0.005 ? 'En paz' : saldo < 0 ? 'Debes' : 'Te deben';
        $('totalSuyo').style.color = saldo < 0 ? colorDe(estado.otro) : colorDe(estado.yo);
        $('totalSuyo').parentElement.classList.remove('oculto');
    } else {
        $('totalSuyo').parentElement.classList.add('oculto');
    }

    caja.classList.remove('oculto');
}

function pintarFiltros() {
    const cajaChips = $('chipsFiltro');
    cajaChips.innerHTML = '';

    const chipTodos = document.createElement('button');
    chipTodos.className = 'chip';
    chipTodos.textContent = 'Todos';
    chipTodos.setAttribute('aria-pressed', String(!estado.filtro.personaId && !estado.filtro.categoria));
    chipTodos.addEventListener('click', () => {
        estado.filtro.personaId = null;
        estado.filtro.categoria = null;
        pintar();
    });
    cajaChips.appendChild(chipTodos);

    for (const p of genteDelGrupo()) {
        const chip = document.createElement('button');
        chip.className = 'chip';
        chip.textContent = p.display_name;
        chip.setAttribute('aria-pressed', String(estado.filtro.personaId === p.id));
        chip.addEventListener('click', () => {
            estado.filtro.personaId = estado.filtro.personaId === p.id ? null : p.id;
            pintar();
        });
        cajaChips.appendChild(chip);
    }
}

function filtrarMovimientos(movimientos) {
    const busqueda = (estado.filtro.texto || '').trim().toLowerCase();
    const persona = estado.filtro.personaId;
    const cat = estado.filtro.categoria;

    return movimientos.filter((m) => {
        if (persona) {
            if (m.tipo === 'gasto' && m.paid_by !== persona) return false;
            if (m.tipo === 'liquidacion' && m.from_user !== persona && m.to_user !== persona) return false;
        }
        if (cat && m.tipo === 'gasto' && m.category !== cat) return false;

        if (busqueda) {
            const desc = (m.description || m.note || '').toLowerCase();
            const catNombre = (m.category || '').toLowerCase();
            const pagador = perfil(m.paid_by || m.from_user)?.display_name.toLowerCase() || '';
            if (!desc.includes(busqueda) && !catNombre.includes(busqueda) && !pagador.includes(busqueda)) {
                return false;
            }
        }
        return true;
    });
}

function etiquetaEstadoApunte(m) {
    if (m.fallo) return ' · no enviado';
    if (m.pendiente) return ' · sin enviar';
    return '';
}

function pintarLista() {
    const lista = $('lista');

    const todosMovimientos = [
        ...gastosDelGrupo().map((g) => ({ ...g, tipo: 'gasto', fecha: g.spent_on })),
        ...liquidacionesDelGrupo().map((l) => ({ ...l, tipo: 'liquidacion', fecha: l.settled_on })),
    ].sort((a, b) => {
        if (a.fecha !== b.fecha) return a.fecha < b.fecha ? 1 : -1;
        return (a.created_at || '') < (b.created_at || '') ? 1 : -1;
    });

    if (!misGrupos().length) {
        lista.innerHTML =
            '<div class="vacio">' +
            '<p class="vacio__titulo">Todavía no hay ningún grupo</p>' +
            '<p>Crea uno arriba para empezar. Por ejemplo, el viaje o los gastos de casa.</p>' +
            '</div>';
        return;
    }

    if (!todosMovimientos.length) {
        lista.innerHTML =
            '<div class="vacio">' +
            '<p class="vacio__titulo">Este grupo está vacío</p>' +
            '<p>Apunta el primer gasto y el saldo se calcula solo.</p>' +
            '</div>';
        return;
    }

    const movimientos = filtrarMovimientos(todosMovimientos);
    const hayFiltroActivo = Boolean(estado.filtro.texto || estado.filtro.personaId || estado.filtro.categoria);

    const infoCaja = $('infoFiltro');
    const infoTexto = $('textoInfoFiltro');
    if (hayFiltroActivo) {
        infoTexto.textContent = movimientos.length +
            (movimientos.length === 1 ? ' resultado' : ' resultados') + ' · ' +
            formatoDinero(sumar(movimientos));
        infoCaja.classList.remove('oculto');
    } else {
        infoCaja.classList.add('oculto');
    }

    if (!movimientos.length) {
        lista.innerHTML =
            '<div class="vacio">' +
            '<p class="vacio__titulo">Sin resultados</p>' +
            '<p>No hay ningún apunte que coincida con tu búsqueda.</p>' +
            '</div>';
        return;
    }

    let html = '';
    let diaActual = null;

    for (const m of movimientos) {
        if (m.fecha !== diaActual) {
            diaActual = m.fecha;
            html += '<h2 class="lista__dia rotulo">' + escapar(tituloDia(diaActual)) + '</h2>';
        }

        const clasesEstado = (m.pendiente ? ' gasto--pendiente' : '') + (m.fallo ? ' gasto--fallido' : '');

        if (m.tipo === 'gasto') {
            const quien = perfil(m.paid_by);
            const reparto = Number(m.payer_share);
            let notaReparto = 'a medias';
            if (reparto >= 0.999) notaReparto = 'solo para ' + quien.display_name;
            else if (reparto <= 0.001) notaReparto = 'solo para ' + perfil(otroId(m.paid_by)).display_name;
            else if (Math.abs(reparto - 0.5) > 0.001) notaReparto = Math.round(reparto * 100) + '/' + Math.round((1 - reparto) * 100);

            const iconoCat = CATEGORY_META[m.category]?.icono || '📦';

            html +=
                '<button class="gasto' + clasesEstado + '"' +
                ' data-color="' + escapar(quien.color) + '"' +
                ' data-gasto="' + escapar(m.id) + '">' +
                '<span class="gasto__icono" aria-hidden="true">' + iconoCat + '</span>' +
                '<span class="gasto__cuerpo">' +
                '<span class="gasto__concepto">' + escapar(m.description) + '</span>' +
                '<span class="gasto__meta">' + escapar(quien.display_name) + ' · ' +
                escapar(m.category) + ' · ' + escapar(notaReparto) +
                escapar(etiquetaEstadoApunte(m)) + '</span>' +
                '</span>' +
                '<span class="gasto__importe cifra">' + formatoDinero(m.amount) + '</span>' +
                '</button>';
        } else {
            const de = perfil(m.from_user);
            const a = perfil(m.to_user);
            html +=
                '<button class="gasto gasto--liquidacion' + clasesEstado + '"' +
                ' data-color="' + escapar(de.color) + '"' +
                ' data-liquidacion="' + escapar(m.id) + '">' +
                '<span class="gasto__icono" aria-hidden="true">💸</span>' +
                '<span class="gasto__cuerpo">' +
                '<span class="gasto__concepto">Pago de ' + escapar(de.display_name) +
                ' a ' + escapar(a.display_name) + '</span>' +
                '<span class="gasto__meta">' + escapar(m.note || 'Cuentas saldadas') +
                escapar(etiquetaEstadoApunte(m)) + '</span>' +
                '</span>' +
                '<span class="gasto__importe cifra">' + formatoDinero(m.amount) + '</span>' +
                '</button>';
        }
    }

    lista.innerHTML = html;

    lista.querySelectorAll('[data-gasto]').forEach((boton) => {
        boton.addEventListener('click', () => abrirHojaGasto(boton.dataset.gasto));
    });

    lista.querySelectorAll('[data-liquidacion]').forEach((boton) => {
        boton.addEventListener('click', () => abrirHojaLiquidarParaEditar(boton.dataset.liquidacion));
    });
}

/**
 * Barra de estado. Distingue los cuatro casos que pide el encargo:
 * sesión caducada, error que necesita intervención, pendiente sin conexión y
 * pendiente por enviar. El caso "guardado en servidor" no ocupa barra.
 */
function pintarEstado() {
    const barra = $('barraEstado');
    const texto = $('textoEstado');
    const pendientes = estado.cola ? estado.cola.pendientes.length : 0;
    const fallidas = estado.cola ? estado.cola.fallidas.length : 0;

    barra.classList.remove('estado--fallo', 'estado--sesion');

    if (estado.sesionCaducada) {
        texto.textContent = 'Sesión caducada · vuelve a entrar para seguir guardando';
        barra.classList.add('estado--sesion');
        barra.classList.remove('oculto');
        return;
    }

    if (fallidas) {
        texto.textContent = fallidas + ' apunte(s) rechazados por el servidor · necesitan tu revisión';
        barra.classList.add('estado--fallo');
        barra.classList.remove('oculto');
        return;
    }

    if (estado.truncado) {
        texto.textContent = 'Hay más apuntes de los que se han podido cargar · el saldo puede no estar completo';
        barra.classList.add('estado--fallo');
        barra.classList.remove('oculto');
        return;
    }

    if (!online()) {
        texto.textContent = pendientes
            ? 'Sin conexión · ' + pendientes + ' apunte(s) esperando'
            : 'Sin conexión · lo que apuntes se guardará y enviará al volver';
        barra.classList.remove('oculto');
        return;
    }

    if (pendientes) {
        texto.textContent = pendientes + ' apunte(s) por enviar';
        barra.classList.remove('oculto');
        return;
    }

    barra.classList.add('oculto');
}

function pintarNovedades() {
    const barra = $('barraNovedades');

    if (estado.novedadesVistas || !estado.desdeVisita || !estado.otro) {
        barra.classList.add('oculto');
        return;
    }

    // Como en la versión anterior, se miran todos los grupos, no solo el
    // activo. Lo que sí cambia: se compara con el id de la otra persona en
    // lugar de "cualquiera que no sea yo", que con un tercer perfil contaba
    // apuntes que no eran suyos.
    const nuevos = [
        ...estado.gastos.filter((g) => !g.pendiente && g.paid_by === estado.otro.id),
        ...estado.liquidaciones.filter((l) => !l.pendiente && l.from_user === estado.otro.id),
    ].filter((m) => m.created_at && m.created_at > estado.desdeVisita);

    if (!nuevos.length) {
        barra.classList.add('oculto');
        return;
    }

    const suma = sumar(nuevos);
    const nombre = estado.otro.display_name;

    $('textoNovedades').textContent = nuevos.length === 1
        ? nombre + ' ha apuntado 1 gasto nuevo · ' + formatoDinero(suma)
        : nombre + ' ha apuntado ' + nuevos.length + ' gastos nuevos · ' + formatoDinero(suma);

    barra.classList.remove('oculto');
}

// ------------------------------------------------------------
//  Estadísticas
// ------------------------------------------------------------
function abrirHojaStats() {
    const g = grupo(estado.grupoActivo);
    if (!g) {
        recado('Elige antes un grupo');
        return;
    }

    const gastos = gastosDelGrupo();
    const caja = $('cuerpoStats');

    if (!gastos.length) {
        caja.innerHTML = '<p style="color:var(--tiza);text-align:center;padding:24px 0">No hay gastos registrados en este grupo todavía.</p>';
        $('veloStats').classList.remove('oculto');
        return;
    }

    const { total, adelantado } = totalesDelGrupo(gastos, estado.perfiles);
    const catsOrdenadas = porCategoria(gastos);

    let html = '';

    html += '<div class="stats-tarjeta">';
    html += '<div class="stats-fila"><span class="rotulo">Total gastado</span><strong class="cifra" style="font-size:20px">' + formatoDinero(total) + '</strong></div>';
    html += '<div class="stats-fila" style="margin-top:8px"><span style="color:var(--tiza);font-size:13px">Número de gastos</span><span class="cifra">' + gastos.length + '</span></div>';
    html += '<div class="stats-fila"><span style="color:var(--tiza);font-size:13px">Gasto medio</span><span class="cifra">' + formatoDinero(total / gastos.length) + '</span></div>';
    html += '</div>';

    html += '<div class="stats-tarjeta" style="margin-top:14px">';
    html += '<span class="rotulo" style="display:block;margin-bottom:10px">Aportación de cada uno</span>';
    for (const p of genteDelGrupo()) {
        const puesto = adelantado[p.id] || 0;
        const pct = total > 0 ? Math.round((puesto / total) * 100) : 0;
        const color = p.color === 'buganvilla' ? 'var(--buganvilla)' : 'var(--laurel)';
        html += '<div class="stats-fila"><span>' + escapar(p.display_name) + '</span><span class="cifra"><strong>' + formatoDinero(puesto) + '</strong> (' + pct + '%)</span></div>';
        html += '<div class="stats-barra"><div class="stats-barra__progreso" style="width:' + pct + '%;background:' + color + '"></div></div>';
    }
    html += '</div>';

    html += '<div class="stats-tarjeta" style="margin-top:14px">';
    html += '<span class="rotulo" style="display:block;margin-bottom:12px">Por categorías</span>';
    for (const [cat, sum] of catsOrdenadas) {
        const pct = total > 0 ? Math.round((sum / total) * 100) : 0;
        const meta = CATEGORY_META[cat] || { icono: '📦', etiqueta: cat };
        html += '<div class="stats-fila">';
        html += '<span>' + meta.icono + ' ' + escapar(meta.etiqueta) + '</span>';
        html += '<span class="cifra"><strong>' + formatoDinero(sum) + '</strong> (' + pct + '%)</span>';
        html += '</div>';
        html += '<div class="stats-barra"><div class="stats-barra__progreso" style="width:' + pct + '%;background:var(--basalto)"></div></div>';
    }
    html += '</div>';

    caja.innerHTML = html;
    $('tituloStats').textContent = 'Estadísticas · ' + g.name;
    $('veloStats').classList.remove('oculto');
}

// ------------------------------------------------------------
//  Compartir, exportar y copia de seguridad
// ------------------------------------------------------------
function resumenTexto() {
    const g = grupo(estado.grupoActivo);
    if (!g) return '';

    const gastos = gastosDelGrupo();
    const { total, adelantado } = totalesDelGrupo(gastos, estado.perfiles);
    const lineas = ['Gastos · ' + g.name, ''];

    for (const p of genteDelGrupo()) {
        lineas.push(p.display_name + ' ha puesto ' + formatoDinero(adelantado[p.id] || 0));
    }

    lineas.push('Total del grupo: ' + formatoDinero(total));
    lineas.push('');

    const saldo = saldoActual();
    if (estado.tipoGrupo === TIPO_GRUPO.SOLO) {
        lineas.push('Grupo individual: no hay reparto.');
    } else if (estado.tipoGrupo === TIPO_GRUPO.MULTI) {
        lineas.push('Más de dos participantes: el reparto múltiple todavía no está disponible.');
    } else if (saldo === null) {
        lineas.push('Falta que la otra persona acepte la invitación.');
    } else if (Math.abs(saldo) < 0.005) {
        lineas.push('Estamos en paz.');
    } else if (saldo > 0) {
        lineas.push(estado.otro.display_name + ' → ' + estado.yo.display_name + ': ' + formatoDinero(Math.abs(saldo)));
    } else {
        lineas.push(estado.yo.display_name + ' → ' + estado.otro.display_name + ': ' + formatoDinero(Math.abs(saldo)));
    }

    return lineas.join('\n');
}

async function compartirBalance() {
    const texto = resumenTexto();
    if (!texto) {
        recado('Elige antes un grupo');
        return;
    }

    if (navigator.share) {
        try {
            await navigator.share({ text: texto });
            return;
        } catch (e) {
            if (e && e.name === 'AbortError') return;
        }
    }

    try {
        await navigator.clipboard.writeText(texto);
        recado('Copiado al portapapeles');
    } catch {
        window.open('https://wa.me/?text=' + encodeURIComponent(texto), '_blank');
    }
}

function descargar(nombre, contenido, tipo) {
    const blob = new Blob([contenido], { type: tipo });
    const url = URL.createObjectURL(blob);
    const enlace = document.createElement('a');
    enlace.href = url;
    enlace.download = nombre;
    document.body.appendChild(enlace);
    enlace.click();
    document.body.removeChild(enlace);
    setTimeout(() => URL.revokeObjectURL(url), 4000);
}

function exportarCSV() {
    const g = grupo(estado.grupoActivo);
    if (!g) {
        recado('Elige antes un grupo');
        return;
    }

    const gastos = gastosDelGrupo();
    const csv = construirCSV(
        { gastos, liquidaciones: liquidacionesDelGrupo(), total: sumar(gastos) },
        (id) => perfil(id).display_name,
        (id) => otroId(id)
    );

    const nombre = 'gastos-' +
        g.name.toLowerCase().replace(/[^a-z0-9áéíóúñ]+/gi, '-').replace(/^-|-$/g, '') +
        '-' + hoyISO() + '.csv';

    descargar(nombre, '\uFEFF' + csv, 'text/csv;charset=utf-8;');
    recado('CSV generado');
}

function descargarBackupJSON() {
    const datos = {
        fecha: new Date().toISOString(),
        version: VERSION_APP,
        perfiles: estado.perfiles,
        grupos: estado.grupos,
        membresias: estado.membresias,
        gastos: estado.gastos,
        liquidaciones: estado.liquidaciones,
    };
    descargar('gastos-backup-' + hoyISO() + '.json', JSON.stringify(datos, null, 2), 'application/json');
    recado('Copia de seguridad descargada');
}

// ------------------------------------------------------------
//  Importar CSV
// ------------------------------------------------------------
let analisisActual = null;

function contextoCSV() {
    return {
        perfiles: [estado.yo, estado.otro].filter(Boolean),
        yoId: estado.yo?.id || null,
        otroId: estado.otro?.id || null,
        grupoId: estado.grupoHojaImportar ?? estado.grupoActivo,
        hoy: hoyISO(),
    };
}

function abrirHojaImportar() {
    const g = grupo(estado.grupoActivo);
    if (!g) {
        recado('Elige antes un grupo');
        return;
    }
    if (!grupoAdmite('importar')) return;
    estado.grupoHojaImportar = estado.grupoActivo;

    analisisActual = null;
    mostrarAviso($('avisoImportar'), '');
    $('entradaTextoCSV').value = '';
    $('entradaArchivo').value = '';
    $('previoImportar').innerHTML = '';
    $('botonConfirmarImportar').classList.add('oculto');
    $('pistaImportar').innerHTML =
        'Se importa al grupo <strong>' + escapar(g.name) + '</strong>. ' +
        'La primera fila tiene que decir qué es cada columna; como mínimo, ' +
        'concepto e importe.';

    pintarBotonDeshacer();
    $('veloImportar').classList.remove('oculto');
}

function importadosDelGrupo() {
    const esImportado = (m) => String(m.client_id || '').startsWith('imp:');
    return {
        gastos: gastosDelGrupo().filter(esImportado),
        liquidaciones: liquidacionesDelGrupo().filter(esImportado),
    };
}

function pintarBotonDeshacer() {
    const boton = $('botonDeshacerImport');
    const { gastos, liquidaciones } = importadosDelGrupo();
    const total = gastos.length + liquidaciones.length;

    if (!total) {
        boton.classList.add('oculto');
        return;
    }

    boton.textContent = 'Borrar lo importado (' + total + (total === 1 ? ' apunte)' : ' apuntes)');
    boton.classList.remove('oculto');
}

async function deshacerImportacion() {
    const g = grupo(estado.grupoActivo);
    if (!g) return;

    const { gastos, liquidaciones } = importadosDelGrupo();
    const total = gastos.length + liquidaciones.length;
    if (!total) return;

    const aviso = '¿Borrar los ' + total + ' apuntes importados de "' + g.name + '"? ' +
        'Suman ' + formatoDinero(sumar(gastos)) + '. Lo que apuntasteis a mano no se toca. ' +
        'No se puede deshacer.';

    if (!confirm(aviso)) return;

    if (!online()) {
        mostrarAviso($('avisoImportar'), 'Para borrar hace falta conexión.');
        return;
    }

    const boton = $('botonDeshacerImport');
    boton.disabled = true;

    try {
        const { error: e1 } = await sb.from('expenses').delete()
            .eq('group_id', g.id).like('client_id', 'imp:%');
        if (e1) throw e1;

        const { error: e2 } = await sb.from('settlements').delete()
            .eq('group_id', g.id).like('client_id', 'imp:%');
        if (e2) throw e2;

        $('veloImportar').classList.add('oculto');
        recado(total + ' apuntes importados borrados');
        await refrescar();
    } catch (error) {
        mostrarAviso($('avisoImportar'), traducirError(error));
    } finally {
        boton.disabled = false;
    }
}

function pintarPrevio(r) {
    const caja = $('previoImportar');

    if (r.error) {
        caja.innerHTML = '';
        mostrarAviso($('avisoImportar'), r.error);
        $('botonConfirmarImportar').classList.add('oculto');
        return;
    }

    mostrarAviso($('avisoImportar'), '');

    const total = r.gastos.reduce((t, g) => t + g.amount, 0);
    const muestra = r.gastos.slice(0, 5);

    let html = '<div class="previo">';
    html += '<p class="previo__cifra">' + r.gastos.length + (r.gastos.length === 1 ? ' gasto' : ' gastos') + '</p>';
    html += '<p class="previo__nota">' + formatoDinero(total) + ' en total' +
            (r.liquidaciones.length ? ' · ' + r.liquidaciones.length + ' liquidación(es)' : '') + '</p>';

    html += '<ul class="previo__lista">';
    for (const p of r.porPersona) {
        html += '<li><strong>' + escapar(p.nombre) + '</strong>: ' + p.cuantos + ' · ' + formatoDinero(p.suma) + '</li>';
    }
    html += '</ul>';

    if (r.sinColumnaPagador) {
        html += '<p class="previo__nota previo__fallos" style="margin-top:10px">' +
                'No hay columna de pagador, así que todo se apunta a tu nombre. ' +
                'Añade una columna «Pagador» si no fue así.</p>';
    } else if (r.pagadorAdivinado) {
        html += '<p class="previo__nota" style="margin-top:10px">' +
                'La columna del pagador la he deducido por los nombres, ' +
                'porque la cabecera no lo dejaba claro.</p>';
    }

    if (muestra.length) {
        html += '<ul class="previo__lista">';
        for (const g of muestra) {
            html += '<li>' + escapar(g.spent_on) + ' · ' + escapar(g.description) +
                    ' · ' + formatoDinero(g.amount) + ' · ' + escapar(perfil(g.paid_by).display_name) + '</li>';
        }
        if (r.gastos.length > muestra.length) {
            html += '<li>y ' + (r.gastos.length - muestra.length) + ' más…</li>';
        }
        html += '</ul>';
    }

    if (r.fallos.length) {
        html += '<ul class="previo__lista previo__fallos">';
        for (const f of r.fallos.slice(0, 5)) html += '<li>' + escapar(f) + '</li>';
        if (r.fallos.length > 5) {
            html += '<li>y ' + (r.fallos.length - 5) + ' problema(s) más</li>';
        }
        html += '</ul>';
    }

    html += '</div>';
    caja.innerHTML = html;

    $('botonConfirmarImportar').textContent =
        'Importar ' + r.gastos.length + (r.gastos.length === 1 ? ' gasto' : ' gastos');
    $('botonConfirmarImportar').classList.remove('oculto');
}

function analizarLoPegado() {
    analisisActual = analizarCSV($('entradaTextoCSV').value, contextoCSV());
    pintarPrevio(analisisActual);
}

function leerArchivo(archivo) {
    if (!archivo) return;
    const lector = new FileReader();
    lector.onload = () => {
        $('entradaTextoCSV').value = String(lector.result || '');
        analizarLoPegado();
    };
    lector.onerror = () => mostrarAviso($('avisoImportar'), 'No he podido leer el archivo.');
    lector.readAsText(archivo, 'UTF-8');
}

async function confirmarImportacion() {
    if (!analisisActual || analisisActual.error) return;

    if (!online()) {
        mostrarAviso($('avisoImportar'), 'Para importar hace falta conexión.');
        return;
    }

    // El destino se fijó al abrir la hoja. Se vuelve a comprobar aquí por si
    // el grupo ha cambiado de tipo mientras la hoja estaba abierta, y que
    // todas las filas analizadas van a ese mismo grupo y no a otro.
    const destino = estado.grupoHojaImportar;
    if (tipoDe(destino) !== TIPO_GRUPO.PAR) {
        mostrarAviso($('avisoImportar'),
            'Este grupo ya no admite importar gastos compartidos. Vuelve a abrir la hoja.');
        return;
    }
    const todas = [...analisisActual.gastos, ...analisisActual.liquidaciones];
    if (todas.some((f) => String(f.group_id) !== String(destino))) {
        mostrarAviso($('avisoImportar'),
            'El análisis no corresponde a este grupo. Vuelve a analizar el archivo.');
        return;
    }

    const boton = $('botonConfirmarImportar');
    boton.disabled = true;
    boton.textContent = 'Importando…';
    pausarRealtime(true);

    try {
        const enLotes = async (tabla, filas) => {
            for (let i = 0; i < filas.length; i += 100) {
                const { error } = await sb.from(tabla)
                    .upsert(filas.slice(i, i + 100), { onConflict: 'client_id' });
                if (error) throw error;
            }
        };

        await enLotes('expenses', analisisActual.gastos);
        if (analisisActual.liquidaciones.length) {
            await enLotes('settlements', analisisActual.liquidaciones);
        }

        const cuantos = analisisActual.gastos.length;
        $('veloImportar').classList.add('oculto');
        analisisActual = null;
        recado(cuantos + (cuantos === 1 ? ' gasto importado' : ' gastos importados'));
        await refrescar();
    } catch (error) {
        mostrarAviso($('avisoImportar'), traducirError(error));
    } finally {
        pausarRealtime(false);
        boton.disabled = false;
    }
}

// ------------------------------------------------------------
//  Grupos
// ------------------------------------------------------------
function abrirHojaGrupos() {
    mostrarAviso($('avisoGrupos'), '');
    $('entradaGrupoNuevo').value = '';
    pintarListaGrupos();
    $('veloGrupos').classList.remove('oculto');
    setTimeout(() => $('entradaGrupoNuevo').focus(), 120);
}

function pintarListaGrupos() {
    const caja = $('listaGrupos');
    caja.innerHTML = '';

    const lista = misGrupos();
    if (!lista.length) {
        const p = document.createElement('p');
        p.style.color = 'var(--tiza)';
        p.style.margin = '0 0 18px';
        p.textContent = 'Todavía no hay ninguno.';
        caja.appendChild(p);
        return;
    }

    for (const g of lista) {
        const cuantos = delGrupo(estado.gastos, g.id).length;

        const ficha = document.createElement('div');
        ficha.className = 'ficha';

        const nombre = document.createElement('span');
        nombre.className = 'ficha__nombre';
        nombre.textContent = g.name;
        const cuenta = document.createElement('span');
        cuenta.className = 'ficha__cuenta';
        cuenta.textContent = ' · ' + cuantos + (cuantos === 1 ? ' gasto' : ' gastos');
        nombre.appendChild(cuenta);

        const renombrar = document.createElement('button');
        renombrar.className = 'ficha__accion';
        renombrar.textContent = 'Renombrar';
        renombrar.addEventListener('click', () => renombrarGrupo(g));

        const vaciar = document.createElement('button');
        vaciar.className = 'ficha__accion ficha__accion--peligro';
        vaciar.textContent = 'Vaciar';
        vaciar.addEventListener('click', () => vaciarGrupo(g));

        const borrar = document.createElement('button');
        borrar.className = 'ficha__accion ficha__accion--peligro';
        borrar.textContent = 'Borrar';
        borrar.addEventListener('click', () => borrarGrupo(g, cuantos));

        ficha.appendChild(nombre);
        ficha.appendChild(renombrar);
        ficha.appendChild(vaciar);
        ficha.appendChild(borrar);
        caja.appendChild(ficha);
    }
}

async function vaciarGrupo(g) {
    const gastos = delGrupo(estado.gastos, g.id);
    const liquidaciones = delGrupo(estado.liquidaciones, g.id);
    const total = gastos.length + liquidaciones.length;

    if (!total) {
        mostrarAviso($('avisoGrupos'), '"' + g.name + '" ya está vacío.');
        return;
    }

    const aviso = '¿Vaciar "' + g.name + '"? Se borran sus ' + total +
        ' apuntes (' + formatoDinero(sumar(gastos)) + '). El grupo se queda, pero sin nada dentro. ' +
        'No se puede deshacer.';

    if (!confirm(aviso)) return;

    if (!online()) {
        mostrarAviso($('avisoGrupos'), 'Para vaciar hace falta conexión.');
        return;
    }

    try {
        const { error: e1 } = await sb.from('expenses').delete().eq('group_id', g.id);
        if (e1) throw e1;
        const { error: e2 } = await sb.from('settlements').delete().eq('group_id', g.id);
        if (e2) throw e2;

        recado('"' + g.name + '" vaciado');
        await refrescar();
        pintarListaGrupos();
    } catch (error) {
        mostrarAviso($('avisoGrupos'), traducirError(error));
    }
}

async function crearGrupo() {
    const nombre = $('entradaGrupoNuevo').value.trim();

    if (!nombre) {
        mostrarAviso($('avisoGrupos'), 'Ponle un nombre al grupo.');
        return;
    }
    if (!online()) {
        mostrarAviso($('avisoGrupos'), 'Para crear un grupo hace falta conexión.');
        return;
    }

    $('botonCrearGrupo').disabled = true;

    try {
        const data = await crearGrupoRemoto(sb, nombre, miId());
        $('entradaGrupoNuevo').value = '';
        recado('Grupo "' + data.name + '" creado');
        await refrescar();
        fijarGrupo(data.id);
        pintarListaGrupos();
    } catch (error) {
        mostrarAviso($('avisoGrupos'), traducirError(error));
        if (error.grupoCreado) await refrescar();
    } finally {
        $('botonCrearGrupo').disabled = false;
    }
}

async function renombrarGrupo(g) {
    const nombre = prompt('Nombre del grupo:', g.name);
    if (nombre === null) return;

    const limpio = nombre.trim();
    if (!limpio) {
        mostrarAviso($('avisoGrupos'), 'El nombre no puede quedar vacío.');
        return;
    }

    try {
        const { data, error } = await sb.from('groups')
            .update({ name: limpio }).eq('id', g.id).select('id');
        if (error) throw error;
        if (!data || !data.length) {
            mostrarAviso($('avisoGrupos'), 'No se ha renombrado: el grupo ya no existe o no puedes modificarlo.');
            await refrescar();
            pintarListaGrupos();
            return;
        }
        recado('Grupo renombrado');
        await refrescar();
        pintarListaGrupos();
    } catch (error) {
        mostrarAviso($('avisoGrupos'), traducirError(error));
    }
}

async function borrarGrupo(g, cuantos) {
    const aviso = cuantos
        ? '¿Borrar "' + g.name + '"? Se borrarán también sus ' + cuantos + ' gasto(s). No se puede deshacer.'
        : '¿Borrar "' + g.name + '"?';
    if (!confirm(aviso)) return;

    try {
        const { data, error } = await sb.from('groups').delete().eq('id', g.id).select('id');
        if (error) throw error;
        if (!data || !data.length) {
            mostrarAviso($('avisoGrupos'), 'No se ha borrado: el grupo ya no existe o no puedes borrarlo.');
            await refrescar();
            pintarListaGrupos();
            return;
        }

        if (String(estado.grupoActivo) === String(g.id)) estado.grupoActivo = null;
        recado('Grupo borrado');
        await refrescar();
        if (!grupo(estado.grupoActivo)) elegirGrupoInicial();
        escucharCambios();
        pintar();
        pintarListaGrupos();
    } catch (error) {
        mostrarAviso($('avisoGrupos'), traducirError(error));
    }
}

// ------------------------------------------------------------
//  Dictado: acceso al micrófono
// ------------------------------------------------------------
function aplicarDictado(texto) {
    const r = interpretarDictado(texto, {
        perfiles: [estado.yo, estado.otro].filter(Boolean),
        yoId: estado.yo?.id || null,
    });
    if (!r) return;

    const puestos = [];

    if (Number.isFinite(r.importe) && r.importe > 0) {
        $('entradaImporte').value = r.importe.toFixed(2).replace('.', ',');
        puestos.push('importe');
    }
    if (r.concepto) { $('entradaConcepto').value = r.concepto; puestos.push('concepto'); }
    if (r.categoria) { $('entradaCategoria').value = r.categoria; puestos.push('categoría'); }
    if (r.fecha) { $('entradaFecha').value = r.fecha; puestos.push('fecha'); }
    if (r.pagador) { estado.formulario.pagador = r.pagador; puestos.push('quién pagó'); }

    if (r.asume === 'ambos') {
        estado.formulario.reparto = 0.5;
    } else if (r.asume === estado.formulario.pagador) {
        estado.formulario.reparto = 1;
        puestos.push('reparto');
    } else if (r.asume) {
        estado.formulario.reparto = 0;
        puestos.push('reparto');
    }

    pintarOpcionesPagador();
    pintarOpcionesReparto();

    recado(puestos.length
        ? 'Listo: ' + puestos.join(', ') + '. Revísalo antes de guardar.'
        : 'No he sacado nada de ahí. Prueba con el importe primero.');
}

const Reconocimiento = window.SpeechRecognition || window.webkitSpeechRecognition;
const PISTA_MICRO = 'Di el importe, en qué fue y quién pagó. Se reparten solos.';
const PISTA_TECLADO = 'Pulsa el micro del teclado y di el importe, en qué fue y quién pagó.';

let escucha = null;
let paradaAutomatica = null;

function pararEscucha() {
    if (escucha) {
        try { escucha.stop(); } catch { /* ya parada */ }
    }
}

function prepararMicro() {
    const boton = $('botonMicro');

    if (!Reconocimiento) {
        boton.classList.add('oculto');
        $('pistaDictado').textContent = PISTA_TECLADO;
        return;
    }

    boton.addEventListener('click', () => {
        if (escucha) { pararEscucha(); return; }

        escucha = new Reconocimiento();
        escucha.lang = 'es-ES';
        escucha.continuous = true;
        escucha.interimResults = true;
        escucha.maxAlternatives = 1;

        let acumulado = '';
        let falloGrave = false;

        escucha.onstart = () => {
            boton.setAttribute('data-escuchando', 'true');
            $('entradaDictado').value = '';
            $('pistaDictado').textContent = 'Escuchando… toca el micro otra vez para parar.';
            clearTimeout(paradaAutomatica);
            paradaAutomatica = setTimeout(pararEscucha, 20000);
        };

        escucha.onresult = (e) => {
            let provisional = '';
            for (let i = e.resultIndex; i < e.results.length; i++) {
                const trozo = e.results[i][0].transcript;
                if (e.results[i].isFinal) acumulado += trozo + ' ';
                else provisional += trozo;
            }
            $('entradaDictado').value = (acumulado + provisional).replace(/\s+/g, ' ').trim();
        };

        escucha.onerror = (e) => {
            const fallo = e && e.error;
            if (fallo === 'aborted') return;

            if (fallo === 'not-allowed' || fallo === 'service-not-allowed') {
                falloGrave = true;
                recado('Sin permiso de micrófono. Revisa Ajustes o usa el micro del teclado.');
            } else if (fallo === 'no-speech') {
                recado('No he oído nada. Acerca el móvil y prueba otra vez.');
            } else if (fallo === 'network') {
                falloGrave = true;
                recado('El dictado necesita conexión. Usa el micro del teclado.');
            } else {
                recado('El micro ha fallado. Puedes usar el del teclado.');
            }
        };

        escucha.onend = () => {
            clearTimeout(paradaAutomatica);
            boton.removeAttribute('data-escuchando');
            escucha = null;
            $('pistaDictado').textContent = PISTA_MICRO;

            const texto = $('entradaDictado').value.trim();
            if (texto) aplicarDictado(texto);
            else if (!falloGrave) recado('No he captado nada. Prueba con el micro del teclado.');
        };

        try {
            escucha.start();
        } catch {
            escucha = null;
            boton.removeAttribute('data-escuchando');
            recado('No he podido abrir el micrófono.');
        }
    });
}

// ------------------------------------------------------------
//  Hoja de gasto
// ------------------------------------------------------------
function pintarOpcionesPagador() {
    const caja = $('opcionesPagador');
    caja.innerHTML = '';

    for (const p of perfilesDelGrupo(estado.grupoHoja ?? estado.grupoActivo, ctxPertenencia())) {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'opcion';
        b.dataset.color = p.color;
        b.textContent = p.display_name;
        b.setAttribute('aria-pressed', String(estado.formulario.pagador === p.id));
        b.addEventListener('click', () => {
            estado.formulario.pagador = p.id;
            pintarOpcionesPagador();
            pintarOpcionesReparto();
        });
        caja.appendChild(b);
    }
}

function pintarOpcionesReparto() {
    const caja = $('opcionesReparto');
    caja.innerHTML = '';

    const pagador = perfil(estado.formulario.pagador);
    const idReceptor = otroId(estado.formulario.pagador);

    // Grupo individual: el gasto es entero de quien lo apunta. No se ofrece
    // ningún reparto, porque no hay nadie con quien repartir.
    if (!idReceptor) {
        estado.formulario.reparto = 1;
        const nota = document.createElement('p');
        nota.className = 'dictado__pista';
        nota.style.margin = '0';
        nota.textContent = 'Grupo individual: el gasto se apunta entero a tu nombre.';
        caja.appendChild(nota);
        return;
    }

    const receptor = perfil(idReceptor);

    const opciones = [
        { valor: 0.5, texto: 'Mitad y mitad' },
        { valor: 1, texto: 'Solo para ' + pagador.display_name },
        { valor: 0, texto: 'Solo para ' + receptor.display_name },
        { valor: 'libre', texto: 'Otro reparto' },
    ];

    const esLibre = estado.formulario.reparto === 'libre';

    for (const o of opciones) {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'opcion';
        b.textContent = o.texto;
        b.setAttribute('aria-pressed', String(estado.formulario.reparto === o.valor));
        b.addEventListener('click', () => {
            estado.formulario.reparto = o.valor;
            pintarOpcionesReparto();
        });
        caja.appendChild(b);
    }

    if (esLibre) {
        const envoltorio = document.createElement('div');
        envoltorio.className = 'campo';
        envoltorio.style.width = '100%';

        const etiqueta = document.createElement('label');
        etiqueta.setAttribute('for', 'entradaPorcentaje');
        etiqueta.textContent = 'Porcentaje que asume ' + pagador.display_name;

        const entrada = document.createElement('input');
        entrada.type = 'number';
        entrada.id = 'entradaPorcentaje';
        entrada.min = '0';
        entrada.max = '100';
        entrada.step = '1';
        entrada.inputMode = 'numeric';
        entrada.value = estado.formulario.repartoLibre;
        entrada.addEventListener('input', (e) => {
            estado.formulario.repartoLibre = e.target.value;
        });

        envoltorio.appendChild(etiqueta);
        envoltorio.appendChild(entrada);
        caja.appendChild(envoltorio);
    }
}

function pintarCategorias() {
    $('entradaCategoria').innerHTML = CATEGORIES
        .map((c) => {
            const meta = CATEGORY_META[c] || { icono: '📦', etiqueta: c };
            return '<option value="' + escapar(c) + '">' + meta.icono + ' ' + escapar(meta.etiqueta) + '</option>';
        })
        .join('');
}

/**
 * Enseña a qué grupo va el gasto. Ya no es un selector.
 *
 * Antes era un `<select>` con todos los grupos visibles, y `guardarGasto`
 * escribía en el grupo elegido ahí, mientras que la validación se había hecho
 * sobre el grupo activo. Se podía abrir la hoja desde un grupo de dos y
 * guardar en uno individual o de tres. Ahora el destino se fija al abrir la
 * hoja y no se puede cambiar desde el formulario.
 */
function pintarGrupoDeLaHoja(grupoId) {
    const g = grupo(grupoId);
    $('entradaGrupo').textContent = g ? g.name : '—';
}

function abrirHojaGasto(id) {
    if (!misGrupos().length) {
        recado('Crea primero un grupo');
        abrirHojaGrupos();
        return;
    }
    const gasto = id ? estado.gastos.find((g) => String(g.id) === String(id)) : null;

    // El destino se fija AQUÍ y no cambia: al editar es el grupo del propio
    // gasto, al crear el grupo activo. Y se valida ese grupo, no el activo:
    // se puede estar editando un gasto de otro grupo.
    const destino = gasto ? gasto.group_id : estado.grupoActivo;
    if (!grupoAdmite('gasto', destino)) return;
    estado.grupoHoja = destino;

    mostrarAviso($('avisoGasto'), '');
    estado.editando = id || null;
    pintarGrupoDeLaHoja(destino);
    $('entradaDictado').value = '';
    if (Reconocimiento) $('pistaDictado').textContent = PISTA_MICRO;

    $('entradaDictado').parentElement.classList.toggle('oculto', Boolean(gasto));
    $('pistaDictado').classList.toggle('oculto', Boolean(gasto));

    if (gasto) {
        $('tituloGasto').textContent = 'Editar gasto';
        $('entradaImporte').value = String(gasto.amount).replace('.', ',');
        $('entradaConcepto').value = gasto.description;
        $('entradaCategoria').value = gasto.category;
        $('entradaFecha').value = gasto.spent_on;
        estado.formulario.pagador = gasto.paid_by;

        const s = Number(gasto.payer_share);
        if (s === 0.5 || s === 1 || s === 0) {
            estado.formulario.reparto = s;
        } else {
            estado.formulario.reparto = 'libre';
            estado.formulario.repartoLibre = Math.round(s * 100);
        }
        $('botonBorrarGasto').classList.remove('oculto');
    } else {
        $('tituloGasto').textContent = 'Nuevo gasto';
        $('entradaImporte').value = '';
        $('entradaConcepto').value = '';
        $('entradaCategoria').value = CATEGORIES[0];
        $('entradaFecha').value = hoyISO();
        estado.formulario.pagador = estado.yo?.id;
        estado.formulario.reparto = hayReparto() ? 0.5 : 1;
        $('botonBorrarGasto').classList.add('oculto');
    }

    pintarOpcionesPagador();
    pintarOpcionesReparto();
    $('veloGasto').classList.remove('oculto');

    if (!gasto) setTimeout(() => $('entradaImporte').focus(), 120);
}

function cerrarHojaGasto() {
    pararEscucha();
    $('veloGasto').classList.add('oculto');
    estado.editando = null;
    estado.grupoHoja = null;
}

function repartoActual() {
    if (estado.formulario.reparto !== 'libre') return Number(estado.formulario.reparto);
    const p = Number(estado.formulario.repartoLibre);
    if (!Number.isFinite(p) || p < 0 || p > 100) return NaN;
    return Math.round(p) / 100;
}

function idCliente() {
    if (crypto.randomUUID) return crypto.randomUUID();
    return 'c' + Date.now() + Math.random().toString(16).slice(2);
}

async function guardarGasto() {
    const gastoExistente = estado.editando
        ? estado.gastos.find((g) => String(g.id) === String(estado.editando)) || null
        : null;

    // El grupo de destino se recalcula aquí, justo antes de construir la fila,
    // y NO se lee de ningún control del formulario. La validación y la
    // escritura tienen que ir al mismo grupo.
    const destino = gastoExistente ? gastoExistente.group_id : estado.grupoHoja;

    const preparada = prepararFilaGasto({
        grupoActivo: destino,
        gastoExistente,
        tipoGrupo: tipoDe(destino),
        miembros: miembrosDe(destino),
        yoId: estado.yo?.id || null,
        formulario: {
            pagador: estado.formulario.pagador,
            reparto: repartoActual(),
        },
        datos: {
            importe: aNumero($('entradaImporte').value),
            concepto: $('entradaConcepto').value,
            categoria: $('entradaCategoria').value,
            fecha: $('entradaFecha').value || hoyISO(),
        },
    });

    if (!preparada.ok) {
        mostrarAviso($('avisoGasto'), preparada.mensaje);
        return;
    }

    const fila = preparada.fila;

    $('botonGuardarGasto').disabled = true;
    mostrarAviso($('avisoGasto'), '');

    try {
        let r;
        if (estado.editando) {
            const actual = gastoExistente;
            r = await editarApunte(sb, {
                tabla: 'expenses',
                lista: estado.gastos,
                id: estado.editando,
                cambios: fila,
                cola: estado.cola,
                online: online(),
                pendiente: Boolean(actual?.pendiente),
            });
        } else {
            fila.client_id = idCliente();
            r = await crearApunte(sb, {
                tabla: 'expenses', fila, cola: estado.cola, online: online(),
            });
            if (r.estado === 'pendiente') {
                estado.gastos.push({ ...fila, id: fila.client_id, pendiente: true });
            }
        }

        const bien = informar(r, { sustantivo: 'Gasto', aviso: $('avisoGasto') });
        if (!bien) { pintar(); return; }

        cerrarHojaGasto();
        guardarCache();

        if (r.estado === 'servidor' || r.estado === 'duplicado') await refrescar();
        else pintar();
    } finally {
        $('botonGuardarGasto').disabled = false;
    }
}

async function borrarGasto() {
    if (!estado.editando) return;
    if (!confirm('¿Borrar este gasto? No se puede deshacer.')) return;

    const idGasto = estado.editando;
    const actual = estado.gastos.find((g) => String(g.id) === String(idGasto));

    const r = await borrarApunte(sb, {
        tabla: 'expenses',
        lista: estado.gastos,
        id: idGasto,
        cola: estado.cola,
        online: online(),
        pendiente: Boolean(actual?.pendiente),
    });

    const bien = informar(r, {
        sustantivo: 'Borrado', aviso: $('avisoGasto'), exito: 'Gasto borrado',
    });
    if (!bien) { pintar(); return; }

    cerrarHojaGasto();
    guardarCache();
    if (r.estado === 'servidor') await refrescar();
    else pintar();
}

// ------------------------------------------------------------
//  Hoja de liquidación
// ------------------------------------------------------------
function abrirHojaLiquidar() {
    if (!grupo(estado.grupoActivo)) {
        recado('Crea primero un grupo');
        return;
    }
    if (!grupoAdmite('saldar')) return;
    estado.grupoHojaLiquidar = estado.grupoActivo;

    estado.editandoLiquidacion = null;
    const saldo = saldoActual() || 0;
    mostrarAviso($('avisoLiquidar'), '');
    $('tituloLiquidar').textContent = 'Saldar · ' + grupo(estado.grupoActivo).name;
    $('botonBorrarLiquidar').classList.add('oculto');
    $('entradaFechaLiquidar').value = hoyISO();

    if (Math.abs(saldo) < 0.005) {
        $('resumenLiquidar').innerHTML =
            '<strong>Nada pendiente</strong>No hace falta que nadie pague, pero puedes registrar un pago igualmente.';
        $('entradaImporteLiquidar').value = '';
    } else if (saldo > 0) {
        $('resumenLiquidar').innerHTML =
            '<strong>' + formatoDinero(Math.abs(saldo)) + '</strong>' +
            escapar(estado.otro.display_name) + ' te paga a ti.';
        $('entradaImporteLiquidar').value = Math.abs(saldo).toFixed(2).replace('.', ',');
    } else {
        $('resumenLiquidar').innerHTML =
            '<strong>' + formatoDinero(Math.abs(saldo)) + '</strong>' +
            'Le pagas a ' + escapar(estado.otro.display_name) + '.';
        $('entradaImporteLiquidar').value = Math.abs(saldo).toFixed(2).replace('.', ',');
    }

    $('entradaNotaLiquidar').value = '';
    $('veloLiquidar').classList.remove('oculto');
}

function abrirHojaLiquidarParaEditar(id) {
    const l = estado.liquidaciones.find((item) => String(item.id) === String(id));
    if (!l) return;

    // Editar una liquidación de OTRO grupo: se valida ese grupo, no el activo.
    if (!grupoAdmite('saldar', l.group_id)) return;
    estado.grupoHojaLiquidar = l.group_id;

    estado.editandoLiquidacion = id;
    mostrarAviso($('avisoLiquidar'), '');
    $('tituloLiquidar').textContent = 'Editar liquidación';
    $('resumenLiquidar').innerHTML =
        '<strong>' + formatoDinero(l.amount) + '</strong>' +
        'Pago de ' + escapar(perfil(l.from_user).display_name) +
        ' a ' + escapar(perfil(l.to_user).display_name);

    $('entradaImporteLiquidar').value = String(l.amount).replace('.', ',');
    $('entradaNotaLiquidar').value = l.note || '';
    $('entradaFechaLiquidar').value = l.settled_on || hoyISO();
    $('botonBorrarLiquidar').classList.remove('oculto');
    $('veloLiquidar').classList.remove('oculto');
}

async function guardarLiquidacion() {
    const importe = aNumero($('entradaImporteLiquidar').value);
    const fecha = $('entradaFechaLiquidar').value || hoyISO();

    if (!Number.isFinite(importe) || importe <= 0) {
        mostrarAviso($('avisoLiquidar'), 'Escribe un importe mayor que cero.');
        return;
    }

    $('botonGuardarLiquidar').disabled = true;
    mostrarAviso($('avisoLiquidar'), '');

    try {
        let r;
        if (estado.editandoLiquidacion) {
            const actual = estado.liquidaciones.find(
                (l) => String(l.id) === String(estado.editandoLiquidacion));
            r = await editarApunte(sb, {
                tabla: 'settlements',
                lista: estado.liquidaciones,
                id: estado.editandoLiquidacion,
                cambios: {
                    amount: importe,
                    note: $('entradaNotaLiquidar').value.trim() || null,
                    settled_on: fecha,
                },
                cola: estado.cola,
                online: online(),
                pendiente: Boolean(actual?.pendiente),
            });
        } else {
            const destino = estado.grupoHojaLiquidar ?? estado.grupoActivo;
            if (tipoDe(destino) !== TIPO_GRUPO.PAR) {
                mostrarAviso($('avisoLiquidar'),
                    'Este grupo ya no admite registrar pagos. Vuelve a abrir la hoja.');
                return;
            }

            const saldo = saldoActual() || 0;
            const fila = {
                group_id: destino,
                from_user: saldo > 0 ? estado.otro.id : estado.yo.id,
                to_user: saldo > 0 ? estado.yo.id : estado.otro.id,
                amount: importe,
                note: $('entradaNotaLiquidar').value.trim() || null,
                settled_on: fecha,
                client_id: idCliente(),
            };
            r = await crearApunte(sb, {
                tabla: 'settlements', fila, cola: estado.cola, online: online(),
            });
            if (r.estado === 'pendiente') {
                estado.liquidaciones.push({ ...fila, id: fila.client_id, pendiente: true });
            }
        }

        const bien = informar(r, { sustantivo: 'Pago', aviso: $('avisoLiquidar') });
        if (!bien) { pintar(); return; }

        $('veloLiquidar').classList.add('oculto');
        guardarCache();
        if (r.estado === 'servidor' || r.estado === 'duplicado') await refrescar();
        else pintar();
    } finally {
        $('botonGuardarLiquidar').disabled = false;
    }
}

async function borrarLiquidacion() {
    if (!estado.editandoLiquidacion) return;
    if (!confirm('¿Borrar esta liquidación? El saldo volverá a reflejar la deuda.')) return;

    const id = estado.editandoLiquidacion;
    const actual = estado.liquidaciones.find((l) => String(l.id) === String(id));

    const r = await borrarApunte(sb, {
        tabla: 'settlements',
        lista: estado.liquidaciones,
        id,
        cola: estado.cola,
        online: online(),
        pendiente: Boolean(actual?.pendiente),
    });

    const bien = informar(r, {
        sustantivo: 'Borrado', aviso: $('avisoLiquidar'), exito: 'Liquidación borrada',
    });
    if (!bien) { pintar(); return; }

    $('veloLiquidar').classList.add('oculto');
    guardarCache();
    if (r.estado === 'servidor') await refrescar();
    else pintar();
}

// ------------------------------------------------------------
//  Tiempo real
//
//  Corrige el riesgo R10: un solo canal, filtrado por el grupo activo,
//  con las recargas agrupadas y sin duplicar suscripción al reentrar.
// ------------------------------------------------------------
let canal = null;
let claveCanal = null;
let realtimePausado = false;
let recargaPendiente = null;

function pausarRealtime(valor) {
    realtimePausado = valor;
}

function programarRefresco() {
    if (realtimePausado) return;
    // Una importación o un borrado en lote generan una ráfaga de eventos:
    // se agrupan en una sola recarga.
    clearTimeout(recargaPendiente);
    recargaPendiente = setTimeout(() => { refrescar(); }, 400);
}

function desconectarRealtime() {
    if (canal) {
        try { sb.removeChannel(canal); } catch { /* ya cerrado */ }
    }
    canal = null;
    claveCanal = null;
}

function escucharCambios() {
    const grupoId = estado.grupoActivo;
    const clave = 'g:' + String(grupoId ?? '');

    // Ya suscrito a lo mismo: no se vuelve a suscribir (evita duplicados
    // en cada SIGNED_IN o al recuperar el foco).
    if (canal && claveCanal === clave) return;

    desconectarRealtime();
    claveCanal = clave;

    const filtro = grupoId ? { filter: 'group_id=eq.' + grupoId } : {};

    canal = sb.channel('gastos:' + clave)
        .on('postgres_changes',
            { event: '*', schema: 'public', table: 'expenses', ...filtro }, programarRefresco)
        .on('postgres_changes',
            { event: '*', schema: 'public', table: 'settlements', ...filtro }, programarRefresco)
        // groups y profiles son tablas pequeñas y sin group_id por el que filtrar.
        .on('postgres_changes',
            { event: '*', schema: 'public', table: 'groups' }, programarRefresco)
        .on('postgres_changes',
            { event: '*', schema: 'public', table: 'profiles' }, programarRefresco)
        .subscribe();
}

// ------------------------------------------------------------
//  Eventos
// ------------------------------------------------------------
function conectarEventos() {
    if (GOOGLE_ACTIVO) {
        $('botonGoogle').classList.remove('oculto');
        $('separadorGoogle').classList.remove('oculto');
        $('botonGoogle').addEventListener('click', accederConGoogle);
    }

    $('formAcceso').addEventListener('submit', (e) => { e.preventDefault(); acceder(); });
    $('botonCambiarModo').addEventListener('click', () => {
        estado.modoAlta = !estado.modoAlta;
        pintarModoAcceso();
    });

    $('botonSalir').addEventListener('click', salir);
    $('botonNuevoGasto').addEventListener('click', () => abrirHojaGasto(null));
    $('botonLiquidar').addEventListener('click', abrirHojaLiquidar);
    $('botonStats').addEventListener('click', abrirHojaStats);
    $('botonCerrarStats').addEventListener('click', () => $('veloStats').classList.add('oculto'));

    $('botonCompartir').addEventListener('click', compartirBalance);
    $('botonExportar').addEventListener('click', exportarCSV);
    $('botonBackupJSON').addEventListener('click', descargarBackupJSON);

    $('botonImportar').addEventListener('click', abrirHojaImportar);
    $('botonElegirArchivo').addEventListener('click', () => $('entradaArchivo').click());
    $('entradaArchivo').addEventListener('change', (e) => leerArchivo(e.target.files[0]));
    $('botonAnalizar').addEventListener('click', analizarLoPegado);
    $('entradaTextoCSV').addEventListener('change', analizarLoPegado);
    $('botonConfirmarImportar').addEventListener('click', confirmarImportacion);
    $('botonDeshacerImport').addEventListener('click', deshacerImportacion);
    $('botonCerrarImportar').addEventListener('click', () => $('veloImportar').classList.add('oculto'));

    $('entradaBusqueda').addEventListener('input', (e) => {
        estado.filtro.texto = e.target.value;
        $('botonLimpiarBusqueda').classList.toggle('oculto', !e.target.value);
        pintarLista();
    });
    $('botonLimpiarBusqueda').addEventListener('click', () => {
        $('entradaBusqueda').value = '';
        estado.filtro.texto = '';
        $('botonLimpiarBusqueda').classList.add('oculto');
        pintarLista();
    });
    $('botonResetFiltros').addEventListener('click', () => {
        $('entradaBusqueda').value = '';
        estado.filtro.texto = '';
        estado.filtro.personaId = null;
        estado.filtro.categoria = null;
        $('botonLimpiarBusqueda').classList.add('oculto');
        pintar();
    });

    $('barraNovedades').addEventListener('click', () => {
        estado.novedadesVistas = true;
        pintarNovedades();
    });

    // La barra de estado es accionable cuando hay algo que resolver.
    $('barraEstado').addEventListener('click', () => {
        if (estado.sesionCaducada) { location.reload(); return; }
        const fallidas = estado.cola ? estado.cola.fallidas : [];
        if (!fallidas.length) return;
        const detalle = fallidas.slice(0, 5)
            .map((t) => '· ' + (t.fallo?.mensaje || 'Rechazado')).join('\n');
        if (confirm('Estos apuntes no se han podido enviar:\n\n' + detalle +
                    '\n\n¿Descartarlos? Aceptar los borra de este dispositivo; ' +
                    'Cancelar los deja para volver a intentarlo.')) {
            estado.cola.descartarFallidas();
        } else {
            estado.cola.reintentarFallidas();
            sincronizar();
        }
        refrescar();
    });

    $('entradaDictado').addEventListener('change', (e) => aplicarDictado(e.target.value));
    $('entradaDictado').addEventListener('keydown', (e) => {
        if (e.key !== 'Enter') return;
        e.preventDefault();
        e.target.blur();
        aplicarDictado(e.target.value);
    });
    prepararMicro();

    $('botonGuardarGasto').addEventListener('click', guardarGasto);
    $('botonBorrarGasto').addEventListener('click', borrarGasto);
    $('botonCerrarGasto').addEventListener('click', cerrarHojaGasto);

    $('botonGuardarLiquidar').addEventListener('click', guardarLiquidacion);
    $('botonBorrarLiquidar').addEventListener('click', borrarLiquidacion);
    $('botonCerrarLiquidar').addEventListener('click', () => $('veloLiquidar').classList.add('oculto'));

    $('botonCrearGrupo').addEventListener('click', crearGrupo);
    $('entradaGrupoNuevo').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') crearGrupo();
    });
    $('botonCerrarGrupos').addEventListener('click', () => $('veloGrupos').classList.add('oculto'));

    for (const idVelo of ['veloGasto', 'veloLiquidar', 'veloGrupos', 'veloImportar', 'veloStats']) {
        $(idVelo).addEventListener('click', (e) => {
            if (e.target.id === idVelo) $(idVelo).classList.add('oculto');
        });
    }

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            for (const v of ['veloGasto', 'veloLiquidar', 'veloGrupos', 'veloImportar', 'veloStats']) {
                $(v).classList.add('oculto');
            }
        } else if ((e.key === 'n' || e.key === 'N') && !e.ctrlKey && !e.metaKey &&
                   document.activeElement.tagName !== 'INPUT' &&
                   document.activeElement.tagName !== 'TEXTAREA') {
            if (!$('pantallaApp').classList.contains('oculto') && $('veloGasto').classList.contains('oculto')) {
                e.preventDefault();
                abrirHojaGasto(null);
            }
        }
    });

    window.addEventListener('online', async () => {
        pintarEstado();
        await sincronizar();
        await refrescar();
    });
    window.addEventListener('offline', pintarEstado);

    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible' && estado.sesion) {
            sincronizar().then(refrescar);
        }
    });
}

// ------------------------------------------------------------
//  Arranque
// ------------------------------------------------------------
let usuarioEnPantalla = null;

async function entrarEnLaApp() {
    const id = miId();
    if (!id) return;

    // Cambio de cuenta en el mismo dispositivo: se recarga entera, para no
    // arrastrar nada del usuario anterior. reload() no corta la ejecución
    // por sí solo, así que hay que volver aquí mismo.
    if (usuarioEnPantalla && usuarioEnPantalla !== id) {
        location.reload();
        return;
    }
    if (usuarioEnPantalla === id) return;   // ya dentro: no se repite el arranque
    usuarioEnPantalla = id;

    $('pantallaAcceso').classList.add('oculto');
    $('pantallaApp').classList.remove('oculto');

    estado.almacen = crearAlmacen(id);
    purgarOtrosUsuarios(id);
    const migracion = migrarDesdeEsquemaAntiguo(id);
    estado.cola = new ColaOffline({ almacen: estado.almacen, userId: id });

    estado.desdeVisita = estado.almacen.leer('visita', null);
    estado.almacen.escribir('visita', new Date().toISOString());

    pintarCategorias();

    if (leerCache()) {
        reponerPendientes();
        pintar();
    }

    await refrescar();
    await sincronizar();
    escucharCambios();

    if (migracion.adoptadas) {
        recado(migracion.adoptadas + ' apunte(s) pendientes de la versión anterior se han recuperado');
    }

    const params = new URLSearchParams(window.location.search);
    const accion = params.get('accion');
    if (accion === 'nuevo-gasto') abrirHojaGasto(null);
    else if (accion === 'saldar') abrirHojaLiquidar();
}

function mostrarAcceso() {
    usuarioEnPantalla = null;
    desconectarRealtime();
    $('pantallaApp').classList.add('oculto');
    $('pantallaAcceso').classList.remove('oculto');

    try {
        const recordado = localStorage.getItem(CLAVE_CORREO);
        if (recordado && !$('entradaCorreo').value) $('entradaCorreo').value = recordado;
    } catch { /* sin almacenamiento */ }

    pintarModoAcceso();
}

async function iniciar() {
    conectarEventos();
    pintarCategorias();
    $('etiquetaVersion').textContent = VERSION_APP;

    const { data } = await sb.auth.getSession();
    estado.sesion = data.session;

    if (estado.sesion) await entrarEnLaApp();
    else mostrarAcceso();

    sb.auth.onAuthStateChange(async (evento, sesion) => {
        estado.sesion = sesion;
        if (sesion && (evento === 'SIGNED_IN' || evento === 'INITIAL_SESSION')) {
            await entrarEnLaApp();
        } else if (sesion && evento === 'TOKEN_REFRESHED') {
            // La sesión vuelve a ser válida: se reintenta lo que quedó parado.
            if (estado.sesionCaducada) {
                estado.sesionCaducada = false;
                estado.cola?.reintentarFallidas();
                await sincronizar();
                await refrescar();
            }
        } else if (!sesion) {
            mostrarAcceso();
        }
    });

    if ('serviceWorker' in navigator) {
        let recargando = false;
        navigator.serviceWorker.addEventListener('controllerchange', () => {
            if (recargando) return;
            recargando = true;
            location.reload();
        });

        navigator.serviceWorker.register('sw.js')
            .then((registro) => {
                registro.update();
                document.addEventListener('visibilitychange', () => {
                    if (document.visibilityState === 'visible') registro.update();
                });
            })
            .catch((e) => console.warn('No se pudo registrar el service worker', e));
    }
}

iniciar();
