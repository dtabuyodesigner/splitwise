// ============================================================
//  Registro de instancias
//
//  ÚNICA FUENTE DE VERDAD de qué despliegues existen.
//
//  Una "instancia" es un despliegue independiente de la MISMA aplicación:
//  mismo HTML, mismo CSS, mismos módulos. Lo único que cambia es a qué
//  proyecto de Supabase habla y bajo qué claves guarda las cosas en el
//  navegador. Dos instancias no comparten ni un dato.
//
//  Para crear una instancia nueva:
//    1. Añade una entrada aquí.
//    2. `npm run instancias`  (regenera index.html, manifest.json y sw.js
//       de cada instancia a partir de las plantillas).
//  No se copia ni se edita nada a mano. Si esos tres archivos dejan de
//  coincidir con lo que genera la plantilla, CI falla.
//
//  Módulo puro: no toca el DOM ni la red. Se importa desde el navegador,
//  desde Node (pruebas) y desde las herramientas de `tools/`.
// ============================================================

/**
 * @typedef {object} Instancia
 * @property {string}  id            Identificador corto. [a-z0-9-]. Único.
 * @property {string}  ruta          Subcarpeta del despliegue. '' = raíz.
 * @property {string}  nombre        Nombre largo, para el manifest y el <title>.
 * @property {string}  nombreCorto   Nombre bajo el icono en la pantalla de inicio.
 * @property {string}  lema          Frase de la pantalla de acceso.
 * @property {string}  supabaseUrl   URL del proyecto de Supabase. Propio y no compartido.
 * @property {string}  supabaseAnonKey  Clave `anon`. Pública por diseño (ver docs/SECURITY.md).
 * @property {string}  [prefijoAlmacen] Prefijo de localStorage. Por defecto `gastos.<id>.v2`.
 * @property {string}  [claveCorreo]    Clave del último correo escrito.
 * @property {string}  [prefijoCache]   Prefijo de la caché del SW. Por defecto `gastos-<id>-`.
 * @property {boolean} [googleActivo]   OAuth de Google. Se configura por proyecto.
 */

/** @type {Instancia[]} */
export const INSTANCIAS = [
    {
        id: 'dani',
        ruta: '',
        nombre: 'Gastos compartidos',
        nombreCorto: 'Gastos',
        lema: 'Lo que pone cada uno y lo que queda por saldar.',

        supabaseUrl: 'https://cmkzcvfjgrgxwqjimtxa.supabase.co',
        supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNta3pjdmZqZ3JneHdxamltdHhhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ3NzU5NzAsImV4cCI6MjEwMDM1MTk3MH0.epSiwj0MO9WWfqETVoEt2E_ijNSzi4x0d-TmgDhAWhQ',

        // Esta instancia es anterior al sistema multi-instancia y ya está
        // instalada en varios móviles. Conserva a propósito los prefijos
        // antiguos: cambiarlos borraría la cola offline pendiente de Dani y
        // Pilar y duplicaría el icono en la pantalla de inicio.
        prefijoAlmacen: 'gastos.v2',
        prefijoCache: 'gastos-',
        claveCorreo: 'gastos.correo',

        googleActivo: false,
    },
    {
        id: 'alba',
        ruta: 'alba',
        nombre: 'Gastos de Alba',
        nombreCorto: 'Gastos Alba',
        lema: 'Lo que pone cada uno y lo que queda por saldar.',

        // PROYECTO DE SUPABASE PROPIO. No comparte absolutamente nada con la
        // instancia `dani`: ni base de datos, ni usuarios, ni sesiones.
        supabaseUrl: 'https://wspcrnqdoucohattians.supabase.co',
        supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndzcGNybnFkb3Vjb2hhdHRpYW5zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc5OTQ3OTIsImV4cCI6MjEwMzU3MDc5Mn0.le9etS045WQzV3LKNG5IUWLiA3pcKkAtrX-iG5MGknw',

        googleActivo: false,
    },
];

/** Instancia que se usa cuando no se puede deducir ninguna (Node, pruebas). */
export const POR_DEFECTO = 'dani';

/** Descriptor completo, con los valores derivados ya resueltos. */
export function normalizar(inst) {
    return {
        googleActivo: false,
        ...inst,
        // El id va ANTES de la versión a propósito: así ningún prefijo puede
        // ser prefijo de otro y `purgarOtrosUsuarios` no puede cruzar instancias.
        prefijoAlmacen: inst.prefijoAlmacen ?? `gastos.${inst.id}.v2`,
        prefijoCache: inst.prefijoCache ?? `gastos-${inst.id}-`,
        // Clave con la que supabase-js guarda la sesión. Explícita para que
        // dos instancias jamás se pisen la sesión aunque compartieran origen.
        claveSesion: `sb-${inst.id}-auth`,
        // Clave del último correo escrito. Se usa ANTES de saber quién entra,
        // así que no puede colgar del user_id, pero sí de la instancia.
        claveCorreo: inst.claveCorreo ?? `gastos.correo.${inst.id}`,
    };
}

/** @type {Record<string, ReturnType<typeof normalizar>>} */
export const REGISTRO = Object.fromEntries(
    INSTANCIAS.map((i) => [i.id, normalizar(i)])
);

/** Rutas de todas las instancias que NO son la raíz, para los guardas del SW. */
export const RUTAS_NO_RAIZ = INSTANCIAS.map((i) => i.ruta).filter(Boolean);
