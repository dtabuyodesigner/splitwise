#!/usr/bin/env node
// ============================================================
//  Añade una instancia al registro
//
//  Lo usa el workflow "Nueva instancia" para no obligar a editar
//  `instancias/registro.js` a mano desde el móvil. También sirve desde la
//  terminal:
//
//      ID=marta NOMBRE='Gastos de Marta' NOMBRE_CORTO='Gastos Marta' \
//      URL=https://xxxx.supabase.co CLAVE=eyJ... \
//      node tools/registrar-instancia.mjs
//
//  Escribe la entrada e inmediatamente vuelve a importar el registro para
//  validarlo. Si el resultado no es válido, deshace el cambio: es preferible
//  no crear la instancia a dejar el registro roto.
// ============================================================
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REGISTRO = resolve(RAIZ, 'instancias/registro.js');

const entorno = {
    id: process.env.ID?.trim(),
    nombre: process.env.NOMBRE?.trim(),
    nombreCorto: process.env.NOMBRE_CORTO?.trim(),
    lema: process.env.LEMA?.trim() || 'Lo que pone cada uno y lo que queda por saldar.',
    supabaseUrl: process.env.URL?.trim().replace(/\/$/, ''),
    supabaseAnonKey: process.env.CLAVE?.trim(),
};

for (const [clave, valor] of Object.entries(entorno)) {
    if (!valor) {
        console.error(`Falta el dato "${clave}".`);
        process.exit(1);
    }
}

if (!/^[a-z0-9-]+$/.test(entorno.id)) {
    console.error(`El id "${entorno.id}" solo admite minúsculas, dígitos y guiones.`);
    process.exit(1);
}

const original = readFileSync(REGISTRO, 'utf8');

if (new RegExp(`id:\\s*'${entorno.id}'`).test(original)) {
    console.error(`La instancia "${entorno.id}" ya está en el registro.`);
    process.exit(1);
}

/** Comillas simples, que es como está escrito el resto del archivo. */
const lit = (s) => "'" + String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";

const entrada = `    {
        id: ${lit(entorno.id)},
        ruta: ${lit(entorno.id)},
        nombre: ${lit(entorno.nombre)},
        nombreCorto: ${lit(entorno.nombreCorto)},
        lema: ${lit(entorno.lema)},

        // Proyecto de Supabase propio. No comparte nada con las demás
        // instancias: ni base de datos, ni usuarios, ni sesiones.
        supabaseUrl: ${lit(entorno.supabaseUrl)},
        supabaseAnonKey: ${lit(entorno.supabaseAnonKey)},

        googleActivo: false,
    },
];`;

const marca = '\n];';
const corte = original.lastIndexOf(marca, original.indexOf('export const POR_DEFECTO'));
if (corte === -1) {
    console.error('No reconozco la forma de instancias/registro.js. Añade la entrada a mano.');
    process.exit(1);
}

const nuevo = original.slice(0, corte) + '\n' + entrada + original.slice(corte + marca.length);
writeFileSync(REGISTRO, nuevo);

// Validación en caliente: se importa lo recién escrito.
try {
    const { validar } = await import(pathToFileURL(resolve(RAIZ, 'tools/instancias.mjs')).href);
    const problemas = validar();
    if (problemas.length) {
        writeFileSync(REGISTRO, original);
        console.error(`\nEl registro quedaría inválido (${problemas.length}); no he cambiado nada:\n`);
        for (const p of problemas) console.error('  · ' + p);
        console.error('');
        process.exit(1);
    }
} catch (e) {
    writeFileSync(REGISTRO, original);
    console.error('No he podido validar el registro; lo dejo como estaba.');
    console.error(e.message);
    process.exit(1);
}

console.log(`Instancia "${entorno.id}" registrada en /${entorno.id}/.`);
console.log('Ahora: node tools/instancias.mjs');
