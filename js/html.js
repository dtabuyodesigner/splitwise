// ============================================================
//  Escapado de HTML
//
//  Corrige el riesgo R8: la versión original usaba
//  `div.textContent = t; return div.innerHTML`, que escapa < > & pero NO
//  las comillas. Como el resultado se interpola dentro de atributos
//  (`data-color="…"`, `data-gasto="…"`, `value="…"`), un valor con una
//  comilla doble permitía inyectar atributos.
//
//  Módulo puro: no depende del DOM, así que se puede probar en Node.
// ============================================================

const MAPA = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
    '`': '&#96;',
};

/** Seguro tanto en contenido de texto como dentro de un atributo entrecomillado. */
export function escapar(texto) {
    return String(texto ?? '').replace(/[&<>"'`]/g, (c) => MAPA[c]);
}
