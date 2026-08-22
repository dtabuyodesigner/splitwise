// ============================================================
//  Cola de envío offline
//
//  Corrige:
//   R2  solo los errores recuperables se encolan y se reintentan
//   R3  cada tarea lleva `owner_user_id` y se valida antes de enviarla
//   R5  update/delete comprueban cuántas filas han cambiado de verdad
//   R6  editar o borrar un apunte todavía pendiente modifica su tarea,
//       en vez de encolar un update contra un id que el servidor no conoce
//   R11 un solo vaciado a la vez
//
//  El cliente de Supabase se inyecta: las pruebas usan uno falso.
// ============================================================
import { CLASE, clasificarError } from './errores.js';

export const TIPO = {
    INSERTAR: 'insertar',
    ACTUALIZAR: 'actualizar',
    BORRAR: 'borrar',
};

export const MAX_INTENTOS = 8;

/** Traduce los nombres de tarea del esquema v1 al de esta versión. */
const HEREDADO = {
    expenses: { tipo: TIPO.INSERTAR, tabla: 'expenses' },
    settlements: { tipo: TIPO.INSERTAR, tabla: 'settlements' },
    expenses_update: { tipo: TIPO.ACTUALIZAR, tabla: 'expenses' },
    expenses_delete: { tipo: TIPO.BORRAR, tabla: 'expenses' },
    settlements_update: { tipo: TIPO.ACTUALIZAR, tabla: 'settlements' },
    settlements_delete: { tipo: TIPO.BORRAR, tabla: 'settlements' },
};

export function normalizarTarea(tarea, userId) {
    if (!tarea) return null;
    if (tarea.tipo && tarea.tabla) {
        return { intentos: 0, ...tarea, owner_user_id: tarea.owner_user_id || userId };
    }
    const mapa = HEREDADO[tarea.tabla];
    if (!mapa) return null;
    return {
        tipo: mapa.tipo,
        tabla: mapa.tabla,
        fila: tarea.fila,
        owner_user_id: tarea.owner_user_id || userId,
        intentos: tarea.intentos || 0,
        adoptada: Boolean(tarea.adoptada),
    };
}

export class ColaOffline {
    /**
     * @param {object} opciones
     * @param {object} opciones.almacen   almacén creado por crearAlmacen()
     * @param {string} opciones.userId    dueño de esta cola
     */
    constructor({ almacen, userId }) {
        this.almacen = almacen;
        this.userId = userId;
        this.vaciando = false;
        this.tareas = (almacen.leer('cola', []) || [])
            .map((t) => normalizarTarea(t, userId))
            .filter(Boolean)
            // Cinturón y tirantes: aunque la clave ya está aislada por usuario,
            // nunca se carga trabajo que diga pertenecer a otra cuenta.
            .filter((t) => t.owner_user_id === userId);
        this.guardar();
    }

    get longitud() { return this.tareas.length; }

    /** Tareas que no se pudieron enviar por un motivo NO recuperable. */
    get fallidas() { return this.tareas.filter((t) => t.fallo); }

    /** Tareas todavía en camino. */
    get pendientes() { return this.tareas.filter((t) => !t.fallo); }

    guardar() {
        this.almacen.escribir('cola', this.tareas);
    }

    encolar(tipo, tabla, fila) {
        this.tareas.push({
            tipo, tabla, fila,
            owner_user_id: this.userId,
            intentos: 0,
        });
        this.guardar();
        return this.tareas[this.tareas.length - 1];
    }

    /** Busca la tarea de inserción todavía pendiente de un client_id dado. */
    insercionPendiente(tabla, clientId) {
        if (!clientId) return null;
        return this.tareas.find(
            (t) => t.tipo === TIPO.INSERTAR && t.tabla === tabla &&
                   t.fila?.client_id === clientId && !t.fallo
        ) || null;
    }

    /**
     * Edita un apunte. Si todavía está en la cola sin enviar, se reescribe la
     * inserción original en lugar de encolar un update contra un id que el
     * servidor nunca ha visto (R6).
     * @returns {'fusionado'|'encolado'}
     */
    editar(tabla, id, cambios, { clientId = null } = {}) {
        const pendiente = this.insercionPendiente(tabla, clientId || id);
        if (pendiente) {
            pendiente.fila = { ...pendiente.fila, ...cambios };
            delete pendiente.fila.id; // nunca se envía un id de cliente como id
            this.guardar();
            return 'fusionado';
        }
        this.encolar(TIPO.ACTUALIZAR, tabla, { id, ...cambios });
        return 'encolado';
    }

    /**
     * Borra un apunte. Si todavía estaba pendiente de insertarse, basta con
     * quitar la tarea: nunca llegó al servidor (R6).
     * @returns {'cancelado'|'encolado'}
     */
    borrar(tabla, id, { clientId = null } = {}) {
        const pendiente = this.insercionPendiente(tabla, clientId || id);
        if (pendiente) {
            this.tareas = this.tareas.filter((t) => t !== pendiente);
            this.guardar();
            return 'cancelado';
        }
        this.encolar(TIPO.BORRAR, tabla, { id });
        return 'encolado';
    }

    /** Quita las tareas marcadas como fallidas (el usuario las descarta). */
    descartarFallidas() {
        this.tareas = this.tareas.filter((t) => !t.fallo);
        this.guardar();
    }

    /** Vuelve a intentar las fallidas (por ejemplo, tras volver a entrar). */
    reintentarFallidas() {
        for (const t of this.tareas) {
            if (t.fallo) { delete t.fallo; t.intentos = 0; }
        }
        this.guardar();
    }

    /**
     * Envía todo lo pendiente.
     *
     * @param {object} sb          cliente de Supabase (o equivalente)
     * @param {object} opciones
     * @param {boolean} opciones.online
     * @param {string}  opciones.userIdSesion  usuario con la sesión abierta AHORA
     * @returns {Promise<{enviadas:number, pendientes:number, fallidas:number,
     *                    sesionCaducada:boolean, rechazadas:Array}>}
     */
    async vaciar(sb, { online = true, userIdSesion = null } = {}) {
        const vacio = {
            enviadas: 0, pendientes: this.pendientes.length,
            fallidas: this.fallidas.length, sesionCaducada: false, rechazadas: [],
        };

        if (this.vaciando) return { ...vacio, motivo: 'ya-en-curso' };
        if (!online) return { ...vacio, motivo: 'sin-conexion' };

        // Nunca se envía la cola de una cuenta con la sesión de otra (R3).
        if (userIdSesion && userIdSesion !== this.userId) {
            return { ...vacio, motivo: 'usuario-distinto' };
        }

        this.vaciando = true;
        let enviadas = 0;
        let sesionCaducada = false;
        const rechazadas = [];

        try {
            for (const tarea of [...this.tareas]) {
                if (tarea.fallo) continue;
                if (tarea.owner_user_id !== this.userId) {
                    rechazadas.push({ tarea, clase: CLASE.PERMISO });
                    tarea.fallo = { clase: CLASE.PERMISO, mensaje: 'Tarea de otra cuenta' };
                    continue;
                }

                const r = await ejecutarTarea(sb, tarea, { online });

                if (r.ok) {
                    this.tareas = this.tareas.filter((t) => t !== tarea);
                    enviadas++;
                    continue;
                }

                tarea.intentos = (tarea.intentos || 0) + 1;

                if (r.clase === CLASE.SESION) {
                    // No se descarta: al volver a entrar se reintenta sola.
                    sesionCaducada = true;
                    break;
                }

                if (r.clase === CLASE.RED && tarea.intentos < MAX_INTENTOS) {
                    continue; // sigue en cola, se reintentará
                }

                // Todo lo demás (permiso, validación, desconocido, o red que
                // ya ha agotado los intentos) deja de reintentarse: si no,
                // la cola no se vacía nunca (riesgo "operaciones que nunca
                // sincronizan").
                tarea.fallo = { clase: r.clase, mensaje: r.mensaje };
                rechazadas.push({ tarea, clase: r.clase, mensaje: r.mensaje });
            }
        } finally {
            this.guardar();
            this.vaciando = false;
        }

        return {
            enviadas,
            pendientes: this.pendientes.length,
            fallidas: this.fallidas.length,
            sesionCaducada,
            rechazadas,
        };
    }
}

/**
 * Ejecuta una tarea contra Supabase.
 *
 * Los update y delete piden `.select('id')` para poder distinguir entre
 * "cambiado" y "no había ninguna fila que cambiar". PostgREST no devuelve
 * error en el segundo caso (R5).
 */
export async function ejecutarTarea(sb, tarea, { online = true } = {}) {
    try {
        if (tarea.tipo === TIPO.INSERTAR) {
            const { error } = await sb.from(tarea.tabla)
                .upsert(tarea.fila, { onConflict: 'client_id' });
            if (error) {
                const c = clasificarError(error, { online });
                // Un choque de unicidad sobre client_id significa que la fila
                // ya estaba: la tarea está cumplida.
                if (c.clase === CLASE.DUPLICADO) return { ok: true, duplicado: true };
                return { ok: false, clase: c.clase, mensaje: c.mensaje };
            }
            return { ok: true };
        }

        if (tarea.tipo === TIPO.ACTUALIZAR) {
            const { id, ...resto } = tarea.fila;
            const { data, error } = await sb.from(tarea.tabla)
                .update(resto).eq('id', id).select('id');
            if (error) {
                const c = clasificarError(error, { online });
                return { ok: false, clase: c.clase, mensaje: c.mensaje };
            }
            if (!data || data.length === 0) {
                return {
                    ok: false,
                    clase: CLASE.PERMISO,
                    mensaje: 'El apunte ya no existe o no puedes modificarlo.',
                };
            }
            return { ok: true };
        }

        if (tarea.tipo === TIPO.BORRAR) {
            const { data, error } = await sb.from(tarea.tabla)
                .delete().eq('id', tarea.fila.id).select('id');
            if (error) {
                const c = clasificarError(error, { online });
                return { ok: false, clase: c.clase, mensaje: c.mensaje };
            }
            // Borrar algo que ya no está es el resultado deseado.
            return { ok: true, yaNoEstaba: !data || data.length === 0 };
        }

        return { ok: false, clase: CLASE.DESCONOCIDO, mensaje: 'Tarea desconocida' };
    } catch (e) {
        const c = clasificarError(e, { online });
        return { ok: false, clase: c.clase, mensaje: c.mensaje };
    }
}
