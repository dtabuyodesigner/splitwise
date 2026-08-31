const FORMATO_TOKEN = /^[A-Za-z0-9_-]{43}$/;

export function construirEnlaceInvitacion({ origin, pathname, token }) {
    return `${origin}${pathname}?invitacion=${encodeURIComponent(token)}`;
}

export function leerTokenInvitacion(search) {
    const token = new URLSearchParams(search).get('invitacion');
    return token && FORMATO_TOKEN.test(token) ? token : null;
}

