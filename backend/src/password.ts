import { base64UrlDecode, base64UrlEncode, timingSafeEqual } from './util';

const encoder = new TextEncoder();

/**
 * 100 tysiecy to sufit PBKDF2 w Workers - wiecej runtime odrzuca. OWASP
 * zaleca dzis kilkakrotnie wiecej, wiec te wartosc trzeba traktowac jako
 * kompromis platformy. Dlatego zapisujemy liczbe iteracji w kazdym hashu:
 * migracja na mocniejsze KDF-y nie wymaga unieważniania istniejacych kont.
 */
const ITERATIONS = 100_000;

async function derive(secret: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), 'PBKDF2', false, [
    'deriveBits',
  ]);

  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations },
    key,
    256,
  );

  return new Uint8Array(bits);
}

/** `pbkdf2$<iteracje>$<sol>$<skrot>`, sol losowa per sekret. */
export async function hashSecret(secret: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await derive(secret, salt, ITERATIONS);

  return `pbkdf2$${ITERATIONS}$${base64UrlEncode(salt)}$${base64UrlEncode(hash)}`;
}

export async function verifySecret(secret: string, stored: string): Promise<boolean> {
  const [scheme, iterations, salt, hash] = stored.split('$');

  if (scheme !== 'pbkdf2' || !iterations || !salt || !hash) {
    return false;
  }

  const count = Number(iterations);

  if (!Number.isInteger(count) || count < 1 || count > ITERATIONS) {
    return false;
  }

  const actual = await derive(secret, base64UrlDecode(salt), count);

  return timingSafeEqual(base64UrlEncode(actual), hash);
}

/**
 * Skrot do porownania, gdy konta nie ma.
 *
 * Bez tego logowanie na nieistniejacy adres konczy sie od razu, a na istniejacy
 * dopiero po policzeniu PBKDF2 - roznica czasu odpowiedzi zdradza, kto ma konto.
 */
export const DUMMY_HASH =
  'pbkdf2$100000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
