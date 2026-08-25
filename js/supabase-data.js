// ============================================================
//  Acceso a datos
//
//  Corrige el riesgo R7: la carga original truncaba en 2500 gastos y 500
//  liquidaciones, y el saldo se calculaba sobre ese conjunto recortado sin
//  ningún aviso. Aquí se pagina hasta agotar, y si se alcanza el tope de
//  seguridad se DEVUELVE la señal `truncado` para que la interfaz lo diga.
//
//  El cliente se inyecta: las pruebas usan uno falso.
// ============================================================
import { PAGINA, MAX_PAGINAS } from './config.js';
import { clasificarError } from './errores.js';

/** Código de PostgreSQL para "la relación no existe". */
const TABLA_INEXISTENTE = new Set(['42P01', 'PGRST205']);

function noExiste(error) {
    if (!error) return false;
    if (TABLA_INEXISTENTE.has(String(error.code))) return true;
    return /does not exist|could not find the table|schema cache/i.test(error.message || '');
}

/**
 * Trae una tabla entera paginando con `.range()`.
 *
 * @param {object} sb
 * @param {string} tabla
 * @param {object} opciones
 * @param {(q:any)=>any} opciones.afinar  aplica orden y filtros a la consulta
 * @param {number} opciones.pagina
 * @param {number} opciones.maxPaginas
 * @returns {Promise<{filas:Array, truncado:boolean, paginas:number}>}
 */
export async function traerTodo(sb, tabla, {
    afinar = (q) => q,
    pagina = PAGINA,
    maxPaginas = MAX_PAGINAS,
} = {}) {
    const filas = [];
    let p = 0;

    for (; p < maxPaginas; p++) {
        const desde = p * pagina;
        const hasta = desde + pagina - 1;

        const { data, error } = await afinar(sb.from(tabla).select('*')).range(desde, hasta);
        if (error) throw error;

        const lote = data || [];
        filas.push(...lote);

        // PostgREST puede recortar la página por su propio `max-rows`. Lo que
        // marca el final no es "he pedido N y me han dado N", sino "me han
        // dado menos de lo que cabía en la página".
        if (lote.length === 0) return { filas, truncado: false, paginas: p + 1 };
        if (lote.length < pagina) return { filas, truncado: false, paginas: p + 1 };
    }

    // Se ha alcanzado el tope de seguridad: hay más datos de los que se han
    // traído. Quien llama DEBE avisar en lugar de calcular un saldo parcial.
    return { filas, truncado: true, paginas: p };
}

/**
 * Carga completa. `group_members` es opcional: si la migración todavía no se
 * ha aplicado, se devuelve `membresias: null` y el resto sigue funcionando.
 */
export async function cargarTodo(sb, { online = true } = {}) {
    const [perfiles, grupos, gastos, liquidaciones, membresias] = await Promise.all([
        traerTodo(sb, 'profiles', { afinar: (q) => q.order('created_at') }),
        traerTodo(sb, 'groups', { afinar: (q) => q.order('created_at') }),
        traerTodo(sb, 'expenses', {
            afinar: (q) => q.order('spent_on', { ascending: false })
                            .order('created_at', { ascending: false })
                            .order('id', { ascending: false }),
        }),
        traerTodo(sb, 'settlements', {
            afinar: (q) => q.order('settled_on', { ascending: false })
                            .order('created_at', { ascending: false })
                            .order('id', { ascending: false }),
        }),
        traerMembresias(sb),
    ]).catch((e) => { throw enriquecer(e, online); });

    // Los traslados van aparte y toleran que la tabla no exista: la
    // aplicación tiene que seguir funcionando en una base donde 0007
    // todavía no se haya aplicado, igual que hace `traerMembresias`.
    const traslados = await traerTraslados(sb);

    return {
        perfiles: perfiles.filas,
        grupos: grupos.filas,
        gastos: gastos.filas,
        liquidaciones: liquidaciones.filas,
        membresias,
        traslados,
        truncado: gastos.truncado || liquidaciones.truncado,
    };
}

/** Traslados de saldo, o `[]` si `0007` no está aplicada todavía. */
export async function traerTraslados(sb) {
    try {
        const { data, error } = await sb.from('balance_transfers').select('*');
        if (error) return [];
        return data || [];
    } catch {
        return [];
    }
}

/**
 * Membresías, o `null` si la tabla todavía no existe.
 *
 * La distinción importa y es de una sola cosa:
 *
 *  · `null`  → la migración 0002 no se ha aplicado. No hay modelo de
 *              pertenencia, así que la interfaz usa el comportamiento
 *              anterior para poder seguir funcionando.
 *  · `[]`    → la tabla existe y esta persona no pertenece a ningún grupo.
 *              **Es un dato, no una laguna**: `group_members` es la fuente de
 *              verdad, y no pertenecer significa no ver nada.
 *
 * Una versión anterior devolvía `null` también para la tabla vacía, para
 * cubrir la ventana entre crear la tabla y ejecutar el backfill. Ya no hace
 * falta —y contradiría la regla de negocio—: la migración crea la tabla y
 * hace el backfill en la MISMA transacción, así que esa ventana no existe.
 */
export async function traerMembresias(sb) {
    try {
        const { filas } = await traerTodo(sb, 'group_members', {
            afinar: (q) => q.order('group_id'),
        });
        return filas;
    } catch (e) {
        if (noExiste(e)) return null;
        throw e;
    }
}

function enriquecer(error, online) {
    const c = clasificarError(error, { online });
    error.clasificacion = c;
    return error;
}

/**
 * Inserta un grupo y registra la pertenencia de quien lo crea (R12).
 * Si `group_members` no existe todavía, el grupo se crea igual.
 */
export async function crearGrupo(sb, nombre, userId) {
    const { data, error } = await sb.from('groups')
        .insert({ name: nombre }).select().single();
    if (error) throw error;

    if (userId) {
        const { error: eM } = await sb.from('group_members')
            .insert({ group_id: data.id, user_id: userId, role: 'owner' });
        if (eM && !noExiste(eM) && String(eM.code) !== '23505') {
            // El grupo ya existe; no se deshace, pero se informa: sin
            // pertenencia el grupo quedará invisible cuando RLS esté activa.
            throw Object.assign(eM, { grupoCreado: data });
        }
    }

    return data;
}
