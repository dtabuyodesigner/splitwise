// ============================================================
//  Configuración y constantes
//  Módulo puro: no toca el DOM ni la red. Se puede importar
//  desde Node para las pruebas.
// ============================================================

export const SUPABASE_URL = 'https://wspcrnqdoucohattians.supabase.co';

// La clave `anon` es pública por diseño: viaja en cualquier cliente web.
// Lo que protege los datos es RLS en el servidor, no el secreto de esta clave.
// Ver docs/SECURITY.md.
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndzcGNybnFkb3Vjb2hhdHRpYW5zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc5OTQ3OTIsImV4cCI6MjEwMzU3MDc5Mn0.le9etS045WQzV3LKNG5IUWLiA3pcKkAtrX-iG5MGknw';

export const LOCALE = 'es-ES';
export const CURRENCY = 'EUR';

// VERSION_APP tiene que coincidir con VERSION en sw.js y con "version" en
// package.json. `npm run verificar-version` lo comprueba, y CI lo ejecuta.
export const VERSION_APP = 'v17';

export const GOOGLE_ACTIVO = false;
export const TOPE_FIEL = 300;

// Paginación de la carga inicial. PAGINA es el tamaño de cada `.range()`.
// MAX_PAGINAS es un tope de seguridad: si se alcanza, la app avisa en pantalla
// en lugar de calcular el saldo con un conjunto truncado en silencio.
export const PAGINA = 1000;
export const MAX_PAGINAS = 200;

export const CATEGORIES = [
    'súper', 'comer fuera', 'casa', 'transporte', 'coche', 'alojamiento',
    'ocio', 'viajes', 'parking', 'salud', 'niños', 'otros',
];

export const CATEGORY_META = {
    'súper':       { icono: '🛒', etiqueta: 'Súper' },
    'comer fuera': { icono: '🍽️', etiqueta: 'Comer fuera' },
    'casa':        { icono: '🏠', etiqueta: 'Casa' },
    'transporte':  { icono: '🚌', etiqueta: 'Transporte' },
    'coche':       { icono: '🚗', etiqueta: 'Coche' },
    'alojamiento': { icono: '🏨', etiqueta: 'Alojamiento' },
    'ocio':        { icono: '🎟️', etiqueta: 'Ocio' },
    'viajes':      { icono: '✈️', etiqueta: 'Viajes' },
    'parking':     { icono: '🅿️', etiqueta: 'Parking' },
    'salud':       { icono: '💊', etiqueta: 'Salud' },
    'niños':       { icono: '👶', etiqueta: 'Niños' },
    'otros':       { icono: '📦', etiqueta: 'Otros' },
};

export const PISTAS_CATEGORIA = {
    'súper':       ['supermercado', 'compra', 'mercadona', 'lidl', 'mercado', 'súper', 'super',
                    'carrefour', 'dia', 'alcampo', 'hiperdino', 'spar', 'eroski', 'aldi', 'consum'],
    'comer fuera': ['cena', 'cenar', 'comida', 'comer', 'desayuno', 'almuerzo', 'tapas',
                    'restaurante', 'bar', 'café', 'cafe', 'copas', 'menú', 'menu', 'merienda',
                    'pizza', 'pizzeria', 'helado', 'bocadillo', 'cerveza', 'cañas', 'burger'],
    'parking':     ['parking', 'aparcamiento', 'garaje', 'estacionamiento',
                    'parquímetro', 'parquimetro', 'zona azul'],
    'alojamiento': ['hotel', 'apartamento', 'airbnb', 'hostal', 'noche', 'alojamiento', 'booking'],
    'transporte':  ['taxi', 'uber', 'cabify', 'bolt', 'tren', 'renfe', 'bus', 'autobús', 'autobus',
                    'metro', 'billete', 'billetes', 'vuelo', 'ryanair', 'vueling', 'iberia',
                    'autopista', 'viñeta', 'ferry', 'barco', 'alsa'],
    'coche':       ['gasolina', 'gasoil', 'diesel', 'diésel', 'peaje', 'coche', 'taller', 'itv'],
    'ocio':        ['entradas', 'entrada', 'museo', 'cine', 'concierto', 'excursión',
                    'excursion', 'visita', 'teatro', 'tour', 'castillo', 'cueva'],
    'salud':       ['farmacia', 'médico', 'medico', 'medicinas', 'dentista'],
    'casa':        ['luz', 'agua', 'internet', 'alquiler', 'ferretería', 'ferreteria', 'ikea', 'leroy'],
    'niños':       ['niños', 'ninos', 'guardería', 'guarderia', 'colegio', 'pañales'],
    'viajes':      ['viaje', 'excursion', 'turismo', 'maleta', 'souvenir'],
};
