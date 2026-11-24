/** Drobiazgi wspoldzielone przez logowanie i profile. */

const encoder = new TextEncoder();

export type Result = {
  status: number;
  body: Record<string, unknown>;
  /** Praca po odpowiedzi (np. push); worker czeka na nia przez `waitUntil`. */
  after?: () => Promise<void>;
};

export function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

export function fail(status: number, error: string, extra: Record<string, unknown> = {}): Result {
  return { status, body: { error, ...extra } };
}

export async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(value));

  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = '';

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function base64UrlDecode(value: string): Uint8Array {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/');
  const filled = padded + '='.repeat((4 - (padded.length % 4)) % 4);

  return Uint8Array.from(atob(filled), (character) => character.charCodeAt(0));
}

/** 256 bitow z generatora kryptograficznego - tyle ma token odswiezajacy. */
export function randomToken(): string {
  return base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
}

/**
 * Szesc cyfr bez przekrzywienia rozkladu: losujemy ponownie, gdy trafimy
 * w ogon, ktory nie miesci sie w pelnej wielokrotnosci miliona.
 */
export function randomCode(): string {
  const limit = 1_000_000;
  const ceiling = Math.floor(0xffffffff / limit) * limit;
  const buffer = new Uint32Array(1);

  let value = 0;

  do {
    crypto.getRandomValues(buffer);
    value = buffer[0]!;
  } while (value >= ceiling);

  return String(value % limit).padStart(6, '0');
}

/** Porownanie odporne na pomiar czasu - `===` zdradza dlugosc wspolnego prefiksu. */
export function timingSafeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) {
    return false;
  }

  let difference = 0;

  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }

  return difference === 0;
}

export function nowIso(): string {
  return new Date().toISOString();
}

export function isoIn(seconds: number): string {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

export function isExpired(iso: string): boolean {
  return Date.parse(iso) <= Date.now();
}
