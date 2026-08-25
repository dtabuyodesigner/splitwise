// ============================================================
//  Cliente de Supabase falso para las pruebas
//
//  Reproduce lo que la app usa de PostgREST, incluida la parte que causa
//  los fallos reales: `update`/`delete` que no afectan a ninguna fila NO
//  devuelven error, solo un array vacío.
//
//  Permite programar fallos por tabla y operación para probar RLS, sesión
//  caducada, red caída y violaciones de restricción.
// ============================================================

export const ERROR_RLS = {
    code: '42501',
    message: 'new row violates row-level security policy for table "expenses"',
};

export const ERROR_SESION = {
    code: 'PGRST301',
    message: 'JWT expired',
    status: 401,
};

export const ERROR_RED = Object.assign(new TypeError('Failed to fetch'), { name: 'TypeError' });

export const ERROR_VALIDACION = {
    code: '23514',
    message: 'new row for relation "expenses" violates check constraint "ck_expenses_importe_positivo"',
};

export const ERROR_DUPLICADO = {
    code: '23505',
    message: 'duplicate key value violates unique constraint "uq_expenses_client_id"',
};

export const ERROR_SERVIDOR = { status: 503, message: 'service unavailable' };

let contador = 0;
const nuevoId = () => 'srv-' + (++contador);

export function crearSupabaseFalso(inicial = {}) {
    const tablas = {
        profiles: [], groups: [], group_members: [],
        expenses: [], settlements: [],
        ...JSON.parse(JSON.stringify(inicial)),
    };

    // { 'expenses.insert': ERROR_RLS }  → esa operación falla siempre.
    const fallos = new Map();
    const registro = [];

    const api = {
        tablas,
        registro,
        /** Programa un fallo. `veces` limita cuántas veces se produce. */
        fallar(clave, error, veces = Infinity) {
            fallos.set(clave, { error, restantes: veces });
        },
        dejarDeFallar(clave) { fallos.delete(clave); },
        /** Tablas cuya lectura debe comportarse como si no existieran. */
        inexistentes: new Set(),

        from(tabla) { return new Consulta(tabla); },
        removeChannel() {},
        channel() { return { on() { return this; }, subscribe() { return this; } }; },
    };

    function comprobarFallo(tabla, op) {
        const f = fallos.get(tabla + '.' + op);
        if (!f || f.restantes <= 0) return null;
        f.restantes--;
        return f.error;
    }

    class Consulta {
        constructor(tabla) {
            this.tabla = tabla;
            this.op = 'select';
            this.filtros = [];
            this.datos = null;
            this.opciones = null;
            this.devolver = false;
            this.rango = null;
        }

        select(cols) {
            if (this.op === 'select') this.cols = cols;
            else this.devolver = true;
            return this;
        }
        insert(d) { this.op = 'insert'; this.datos = d; return this; }
        upsert(d, o) { this.op = 'upsert'; this.datos = d; this.opciones = o; return this; }
        update(d) { this.op = 'update'; this.datos = d; return this; }
        delete() { this.op = 'delete'; return this; }
        eq(col, val) { this.filtros.push(['eq', col, val]); return this; }
        like(col, val) { this.filtros.push(['like', col, val]); return this; }
        order() { return this; }
        limit(n) { this.tope = n; return this; }
        range(a, b) { this.rango = [a, b]; return this; }
        single() { this.uno = true; return this; }

        coincide(fila) {
            return this.filtros.every(([tipo, col, val]) => {
                if (tipo === 'eq') return String(fila[col]) === String(val);
                if (tipo === 'like') {
                    const re = new RegExp('^' + String(val).replace(/%/g, '.*') + '$');
                    return re.test(String(fila[col] ?? ''));
                }
                return true;
            });
        }

        ejecutar() {
            const tabla = this.tabla;
            registro.push({ tabla, op: this.op });

            if (this.op === 'select' && api.inexistentes.has(tabla)) {
                return { data: null, error: { code: '42P01', message: 'relation "' + tabla + '" does not exist' } };
            }

            const error = comprobarFallo(tabla, this.op);
            if (error) {
                if (error instanceof Error) throw error;
                return { data: null, error };
            }

            if (!tablas[tabla]) tablas[tabla] = [];
            const filas = tablas[tabla];

            if (this.op === 'select') {
                let out = filas.filter((f) => this.coincide(f));
                if (this.rango) out = out.slice(this.rango[0], this.rango[1] + 1);
                else if (this.tope) out = out.slice(0, this.tope);
                const copia = out.map((f) => ({ ...f }));
                return this.uno
                    ? { data: copia[0] ?? null, error: copia.length ? null : { code: 'PGRST116', message: 'no rows' } }
                    : { data: copia, error: null };
            }

            if (this.op === 'insert' || this.op === 'upsert') {
                const entrantes = Array.isArray(this.datos) ? this.datos : [this.datos];
                const creadas = [];

                for (const fila of entrantes) {
                    const clave = this.opciones?.onConflict;
                    if (clave && fila[clave] != null) {
                        const idx = filas.findIndex((f) => f[clave] === fila[clave]);
                        if (idx !== -1) {
                            // upsert: sobrescribe. insert: choque de unicidad.
                            if (this.op === 'upsert') {
                                filas[idx] = { ...filas[idx], ...fila };
                                creadas.push({ ...filas[idx] });
                                continue;
                            }
                            return { data: null, error: ERROR_DUPLICADO };
                        }
                    }
                    if (this.op === 'insert' && fila.client_id != null &&
                        filas.some((f) => f.client_id === fila.client_id)) {
                        return { data: null, error: ERROR_DUPLICADO };
                    }
                    const nueva = { id: nuevoId(), created_at: new Date(2026, 0, 1).toISOString(), ...fila };
                    filas.push(nueva);
                    creadas.push({ ...nueva });
                }

                return { data: this.devolver || this.uno ? (this.uno ? creadas[0] : creadas) : null, error: null };
            }

            if (this.op === 'update') {
                const tocadas = [];
                for (let i = 0; i < filas.length; i++) {
                    if (!this.coincide(filas[i])) continue;
                    filas[i] = { ...filas[i], ...this.datos };
                    tocadas.push({ ...filas[i] });
                }
                // PostgREST NO devuelve error cuando no cambia nada.
                return { data: this.devolver || this.uno ? tocadas : null, error: null };
            }

            if (this.op === 'delete') {
                const quedan = [];
                const borradas = [];
                for (const f of filas) {
                    if (this.coincide(f)) borradas.push({ ...f });
                    else quedan.push(f);
                }
                tablas[tabla] = quedan;
                return { data: this.devolver || this.uno ? borradas : null, error: null };
            }

            return { data: null, error: { message: 'operación no soportada' } };
        }

        then(resolver, rechazar) {
            try {
                return Promise.resolve(this.ejecutar()).then(resolver, rechazar);
            } catch (e) {
                return Promise.reject(e).then(resolver, rechazar);
            }
        }
    }

    return api;
}

/** localStorage falso, con enumeración, para probar el aislamiento. */
export function crearAlmacenFalso(inicial = {}) {
    const datos = new Map(Object.entries(inicial));
    return {
        getItem: (k) => (datos.has(k) ? datos.get(k) : null),
        setItem: (k, v) => { datos.set(k, String(v)); },
        removeItem: (k) => { datos.delete(k); },
        key: (i) => [...datos.keys()][i] ?? null,
        get length() { return datos.size; },
        volcado: () => Object.fromEntries(datos),
    };
}
