import type { Env } from './env';
import { consumeCode, issueCode } from './mail';
import { DUMMY_HASH, hashSecret, verifySecret } from './password';
import { clearFailures, lockedUntil, recordFailure } from './throttle';
import {
  base64UrlDecode,
  base64UrlEncode,
  fail,
  isExpired,
  isoIn,
  nowIso,
  randomToken,
  sha256,
  type Result,
} from './util';

const encoder = new TextEncoder();

/** Kwadrans: tokenu dostepu nie da sie uniewaznic, wiec ma zyc krotko. */
const ACCESS_TTL_SECONDS = 15 * 60;

const REFRESH_TTL_SECONDS = 30 * 24 * 60 * 60;

const MIN_PASSWORD = 8;

/** Gorny limit chroni przed wyslaniem megabajtowego "hasla" do PBKDF2. */
const MAX_PASSWORD = 128;

export interface AccessClaims {
  userId: string;
  /** Rodzina tokenu odswiezajacego, czyli "to urzadzenie". */
  familyId: string;
  /** Aktualnie wybrany profil; `null` zaraz po zalogowaniu. */
  profileId: string | null;
}

export interface SessionUser {
  id: string;
  email: string;
}

// --- token dostepu -----------------------------------------------------------

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  );
}

export async function signAccessToken(env: Env, claims: AccessClaims): Promise<string> {
  const issuedAt = Math.floor(Date.now() / 1000);

  const header = base64UrlEncode(encoder.encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const payload = base64UrlEncode(
    encoder.encode(
      JSON.stringify({
        sub: claims.userId,
        fid: claims.familyId,
        pid: claims.profileId,
        iat: issuedAt,
        exp: issuedAt + ACCESS_TTL_SECONDS,
      }),
    ),
  );

  const data = `${header}.${payload}`;
  const signature = await crypto.subtle.sign(
    'HMAC',
    await hmacKey(env.JWT_SECRET),
    encoder.encode(data),
  );

  return `${data}.${base64UrlEncode(new Uint8Array(signature))}`;
}

/** Weryfikacja bez zapytania do bazy - podpis sprawdza `crypto.subtle.verify`. */
export async function verifyAccessToken(env: Env, token: string): Promise<AccessClaims | null> {
  const parts = token.split('.');

  if (parts.length !== 3) {
    return null;
  }

  const [header, payload, signature] = parts as [string, string, string];

  try {
    const valid = await crypto.subtle.verify(
      'HMAC',
      await hmacKey(env.JWT_SECRET),
      base64UrlDecode(signature),
      encoder.encode(`${header}.${payload}`),
    );

    if (!valid) {
      return null;
    }

    const claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(payload))) as {
      sub?: string;
      fid?: string;
      pid?: string | null;
      exp?: number;
    };

    if (!claims.sub || !claims.fid || !claims.exp || claims.exp * 1000 <= Date.now()) {
      return null;
    }

    return { userId: claims.sub, familyId: claims.fid, profileId: claims.pid ?? null };
  } catch {
    return null;
  }
}

// --- sesja -------------------------------------------------------------------

export interface Session {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  user: SessionUser;
}

async function issueSession(
  env: Env,
  user: SessionUser,
  options: { familyId?: string; profileId?: string | null } = {},
): Promise<Session> {
  const refreshToken = randomToken();
  const familyId = options.familyId ?? crypto.randomUUID();
  const profileId = options.profileId ?? null;

  await env.DB.prepare(
    `INSERT INTO RefreshToken (tokenHash, userId, profileId, familyId, expiresAt, createdAt)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(await sha256(refreshToken), user.id, profileId, familyId, isoIn(REFRESH_TTL_SECONDS), nowIso())
    .run();

  return {
    accessToken: await signAccessToken(env, { userId: user.id, familyId, profileId }),
    refreshToken,
    expiresIn: ACCESS_TTL_SECONDS,
    user,
  };
}

/**
 * Wymiana tokenu odswiezajacego na nowy, z wykryciem kradziezy: uzyty drugi raz
 * oznacza kopie, wiec cala rodzina leci do kosza (jak w Pitstop). Profil
 * wybrany na urzadzeniu przechodzi na nowy token.
 */
async function rotateSession(env: Env, refreshToken: string): Promise<Session | null> {
  const tokenHash = await sha256(refreshToken);

  const stored = await env.DB.prepare(
    `SELECT userId, profileId, familyId, expiresAt, usedAt FROM RefreshToken WHERE tokenHash = ?`,
  )
    .bind(tokenHash)
    .first<{
      userId: string;
      profileId: string | null;
      familyId: string;
      expiresAt: string;
      usedAt: string | null;
    }>();

  if (!stored) {
    return null;
  }

  if (stored.usedAt) {
    await env.DB.prepare('DELETE FROM RefreshToken WHERE familyId = ?').bind(stored.familyId).run();

    return null;
  }

  if (isExpired(stored.expiresAt)) {
    return null;
  }

  const user = await env.DB.prepare('SELECT id, email FROM User WHERE id = ?')
    .bind(stored.userId)
    .first<SessionUser>();

  if (!user) {
    return null;
  }

  await env.DB.prepare('UPDATE RefreshToken SET usedAt = ? WHERE tokenHash = ?')
    .bind(nowIso(), tokenHash)
    .run();

  return issueSession(env, user, { familyId: stored.familyId, profileId: stored.profileId });
}

/** Przypina wybrany profil do urzadzenia i zwraca nowy token dostepu. */
export async function bindProfile(
  env: Env,
  claims: AccessClaims,
  profileId: string,
): Promise<{ accessToken: string; expiresIn: number }> {
  await env.DB.prepare('UPDATE RefreshToken SET profileId = ? WHERE familyId = ? AND usedAt IS NULL')
    .bind(profileId, claims.familyId)
    .run();

  return {
    accessToken: await signAccessToken(env, { ...claims, profileId }),
    expiresIn: ACCESS_TTL_SECONDS,
  };
}

// --- walidacja ---------------------------------------------------------------

function normalizeEmail(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }

  const email = value.trim().toLowerCase();

  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) && email.length <= 254 ? email : null;
}

function validPassword(value: unknown): value is string {
  return typeof value === 'string' && value.length >= MIN_PASSWORD && value.length <= MAX_PASSWORD;
}

function validCode(value: unknown): value is string {
  return typeof value === 'string' && /^\d{6}$/.test(value);
}

interface UserRow extends SessionUser {
  passwordHash: string;
  emailVerified: number;
}

async function findUser(env: Env, email: string): Promise<UserRow | null> {
  return env.DB.prepare(
    'SELECT id, email, passwordHash, emailVerified FROM User WHERE email = ?',
  )
    .bind(email)
    .first<UserRow>();
}

// --- trasy -------------------------------------------------------------------

/**
 * Rejestracja. Konto czeka na potwierdzenie adresu kodem z maila i do tego
 * czasu nie da sie na nie zalogowac.
 *
 * Zajety adres zwracamy otwarcie (409), swiadomie: to aplikacja domowa, a ukrycie
 * tej informacji kosztowaloby uczciwych uzytkownikow zagadkowym "sprawdz skrzynke".
 * Niepotwierdzone konto mozna zarejestrowac ponownie - nowe haslo je nadpisuje,
 * wiec nikt nie zablokuje cudzego adresu, rejestrujac go bez dostepu do skrzynki.
 */
export async function handleRegister(env: Env, body: Record<string, unknown>): Promise<Result> {
  const email = normalizeEmail(body.email);

  if (!email) {
    return fail(400, 'invalid_email');
  }

  if (!validPassword(body.password)) {
    return fail(400, 'invalid_password');
  }

  const existing = await findUser(env, email);

  if (existing?.emailVerified) {
    return fail(409, 'email_taken');
  }

  const passwordHash = await hashSecret(body.password);

  if (existing) {
    await env.DB.prepare('UPDATE User SET passwordHash = ? WHERE id = ?')
      .bind(passwordHash, existing.id)
      .run();
  } else {
    await env.DB.prepare(
      'INSERT INTO User (id, email, passwordHash, emailVerified, createdAt) VALUES (?, ?, ?, 0, ?)',
    )
      .bind(crypto.randomUUID(), email, passwordHash, nowIso())
      .run();
  }

  const outcome = await issueCode(env, email, 'verify');

  if (outcome === 'mail_failed') {
    return fail(502, 'mail_failed');
  }

  return { status: 200, body: { status: 'verification_required' } };
}

export async function handleResendVerification(
  env: Env,
  body: Record<string, unknown>,
): Promise<Result> {
  const email = normalizeEmail(body.email);

  if (!email) {
    return fail(400, 'invalid_email');
  }

  const user = await findUser(env, email);

  // Odpowiedz ta sama bez wzgledu na to, czy konto istnieje i czy czeka na kod.
  if (user && !user.emailVerified) {
    const outcome = await issueCode(env, email, 'verify');

    if (outcome === 'cooldown') {
      return fail(429, 'too_soon');
    }

    if (outcome === 'mail_failed') {
      return fail(502, 'mail_failed');
    }
  }

  return { status: 200, body: { status: 'ok' } };
}

export async function handleVerifyEmail(env: Env, body: Record<string, unknown>): Promise<Result> {
  const email = normalizeEmail(body.email);

  if (!email || !validCode(body.code)) {
    return fail(400, 'invalid_request');
  }

  const user = await findUser(env, email);

  if (!user || !(await consumeCode(env, email, 'verify', body.code))) {
    return fail(401, 'invalid_code');
  }

  await env.DB.prepare('UPDATE User SET emailVerified = 1 WHERE id = ?').bind(user.id).run();

  return { status: 200, body: { session: await issueSession(env, user) } };
}

export async function handleLogin(env: Env, body: Record<string, unknown>): Promise<Result> {
  const email = normalizeEmail(body.email);

  if (!email || typeof body.password !== 'string' || body.password.length > MAX_PASSWORD) {
    return fail(400, 'invalid_request');
  }

  const throttleKey = `login:${email}`;
  const locked = await lockedUntil(env, throttleKey);

  if (locked) {
    return fail(429, 'locked', { retryAt: locked });
  }

  const user = await findUser(env, email);

  // Haslo liczymy zawsze, takze dla nieistniejacego konta - patrz DUMMY_HASH.
  const matches = await verifySecret(body.password, user?.passwordHash ?? DUMMY_HASH);

  if (!user || !matches) {
    await recordFailure(env, throttleKey);

    return fail(401, 'invalid_credentials');
  }

  await clearFailures(env, throttleKey);

  if (!user.emailVerified) {
    return fail(403, 'email_not_verified');
  }

  return { status: 200, body: { session: await issueSession(env, user) } };
}

export async function handleRefresh(env: Env, body: Record<string, unknown>): Promise<Result> {
  if (typeof body.refreshToken !== 'string') {
    return fail(400, 'invalid_request');
  }

  const session = await rotateSession(env, body.refreshToken);

  return session ? { status: 200, body: { session } } : fail(401, 'invalid_refresh_token');
}

export async function handleSignOut(env: Env, body: Record<string, unknown>): Promise<Result> {
  if (typeof body.refreshToken === 'string') {
    const stored = await env.DB.prepare('SELECT familyId FROM RefreshToken WHERE tokenHash = ?')
      .bind(await sha256(body.refreshToken))
      .first<{ familyId: string }>();

    if (stored) {
      await env.DB.batch([
        env.DB.prepare('DELETE FROM RefreshToken WHERE familyId = ?').bind(stored.familyId),
        // Po wylogowaniu telefon nie ma dostawac wiadomosci do tego domu.
        env.DB.prepare('DELETE FROM PushToken WHERE familyId = ?').bind(stored.familyId),
      ]);
    }
  }

  return { status: 200, body: { status: 'ok' } };
}

/** Zawsze 200: odpowiedz nie moze zdradzac, czy dany adres ma konto. */
export async function handleForgotPassword(
  env: Env,
  body: Record<string, unknown>,
): Promise<Result> {
  const email = normalizeEmail(body.email);

  if (!email) {
    return fail(400, 'invalid_email');
  }

  const user = await findUser(env, email);

  if (user) {
    await issueCode(env, email, 'reset');
  }

  return { status: 200, body: { status: 'ok' } };
}

/**
 * Ustawia nowe haslo kodem z maila i wylogowuje wszystkie urzadzenia.
 * Poprawny kod dowodzi tez dostepu do skrzynki, wiec potwierdza adres.
 */
export async function handleResetPassword(
  env: Env,
  body: Record<string, unknown>,
): Promise<Result> {
  const email = normalizeEmail(body.email);

  if (!email || !validCode(body.code) || !validPassword(body.newPassword)) {
    return fail(400, 'invalid_request');
  }

  const user = await findUser(env, email);

  if (!user || !(await consumeCode(env, email, 'reset', body.code))) {
    return fail(401, 'invalid_code');
  }

  await env.DB.batch([
    env.DB.prepare('UPDATE User SET passwordHash = ?, emailVerified = 1 WHERE id = ?').bind(
      await hashSecret(body.newPassword),
      user.id,
    ),
    env.DB.prepare('DELETE FROM RefreshToken WHERE userId = ?').bind(user.id),
  ]);

  await clearFailures(env, `login:${email}`);

  return { status: 200, body: { status: 'ok' } };
}

/** Sprawdzenie hasla zalogowanego konta - dla odzyskiwania PIN-u. */
export async function verifyAccountPassword(
  env: Env,
  userId: string,
  password: unknown,
): Promise<'ok' | 'wrong' | { locked: string }> {
  if (typeof password !== 'string' || password.length > MAX_PASSWORD) {
    return 'wrong';
  }

  const user = await env.DB.prepare('SELECT email, passwordHash FROM User WHERE id = ?')
    .bind(userId)
    .first<{ email: string; passwordHash: string }>();

  if (!user) {
    return 'wrong';
  }

  // Ten sam licznik co przy logowaniu: zgadywanie hasla tym endpointem
  // nie moze omijac blokady.
  const throttleKey = `login:${user.email}`;
  const locked = await lockedUntil(env, throttleKey);

  if (locked) {
    return { locked };
  }

  if (!(await verifySecret(password, user.passwordHash))) {
    await recordFailure(env, throttleKey);

    return 'wrong';
  }

  await clearFailures(env, throttleKey);

  return 'ok';
}
