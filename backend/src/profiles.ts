import { bindProfile, verifyAccountPassword, type AccessClaims } from './auth';
import type { Env } from './env';
import { hashSecret, verifySecret } from './password';
import { clearFailures, lockedUntil, recordFailure } from './throttle';
import { fail, nowIso, type Result } from './util';

export type Role = 'admin' | 'member' | 'restricted';

export interface Permissions {
  controlLights: boolean;
  controlBlinds: boolean;
  controlHeating: boolean;
  runScenes: boolean;
  editScenes: boolean;
  manageSettings: boolean;
}

const ROLES: readonly Role[] = ['admin', 'member', 'restricted'];

/** Domownicy, nie flota: osiem profili wystarczy, a ogranicza zasmiecanie bazy. */
const MAX_PROFILES = 8;

const MAX_NAME = 30;

const MAX_ROOMS = 50;

/**
 * Domyslne uprawnienia roli.
 *
 * `restricted` to profil typu Dziecko: wlacza i wylacza swiatla oraz rolety,
 * ale nie zmienia scen ani ustawien.
 */
const PRESETS: Record<Role, Permissions> = {
  admin: {
    controlLights: true,
    controlBlinds: true,
    controlHeating: true,
    runScenes: true,
    editScenes: true,
    manageSettings: true,
  },
  member: {
    controlLights: true,
    controlBlinds: true,
    controlHeating: true,
    runScenes: true,
    editScenes: false,
    manageSettings: false,
  },
  restricted: {
    controlLights: true,
    controlBlinds: true,
    controlHeating: false,
    runScenes: false,
    editScenes: false,
    manageSettings: false,
  },
};

/** Administrator ma wszystko; edycja scen i ustawien nie nalezy do nikogo innego. */
function normalizePermissions(role: Role, input: unknown): Permissions {
  if (role === 'admin') {
    return { ...PRESETS.admin };
  }

  const permissions = { ...PRESETS[role] };

  if (input && typeof input === 'object') {
    const candidate = input as Record<string, unknown>;

    for (const key of ['controlLights', 'controlBlinds', 'controlHeating', 'runScenes'] as const) {
      if (typeof candidate[key] === 'boolean') {
        permissions[key] = candidate[key];
      }
    }
  }

  return permissions;
}

interface ProfileRow {
  id: string;
  userId: string;
  name: string;
  color: string;
  role: Role;
  pinHash: string | null;
  permissions: string;
  allowedRooms: string | null;
}

function publicProfile(row: ProfileRow): Record<string, unknown> {
  return {
    id: row.id,
    name: row.name,
    color: row.color,
    role: row.role,
    hasPin: row.pinHash !== null,
    // Profile zapisane przed dodaniem nowego uprawnienia dostają domyślną wartość roli.
    permissions:
      row.role === 'admin'
        ? { ...PRESETS.admin }
        : { ...PRESETS[row.role], ...(JSON.parse(row.permissions) as Partial<Permissions>), editScenes: false, manageSettings: false },
    allowedRooms: row.allowedRooms ? (JSON.parse(row.allowedRooms) as string[]) : null,
  };
}

// --- walidacja ---------------------------------------------------------------

function validName(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length >= 1 && value.trim().length <= MAX_NAME;
}

function validColor(value: unknown): value is string {
  return typeof value === 'string' && /^#[0-9a-fA-F]{6}$/.test(value);
}

function validRole(value: unknown): value is Role {
  return typeof value === 'string' && (ROLES as readonly string[]).includes(value);
}

function validPin(value: unknown): value is string {
  return typeof value === 'string' && /^\d{4}$/.test(value);
}

/** `undefined` = pole pominiete, `null` = wszystkie pokoje, tablica = lista; `false` = zly format. */
function parseRooms(value: unknown): string[] | null | undefined | false {
  if (value === undefined || value === null) {
    return value;
  }

  if (
    !Array.isArray(value) ||
    value.length > MAX_ROOMS ||
    !value.every((room) => typeof room === 'string' && room.length >= 1 && room.length <= 64)
  ) {
    return false;
  }

  return [...new Set(value as string[])];
}

// --- dostep ------------------------------------------------------------------

async function loadProfile(env: Env, userId: string, id: string): Promise<ProfileRow | null> {
  return env.DB.prepare(
    `SELECT id, userId, name, color, role, pinHash, permissions, allowedRooms
     FROM Profile WHERE id = ? AND userId = ?`,
  )
    .bind(id, userId)
    .first<ProfileRow>();
}

/**
 * Rola administratora sprawdzana w bazie, nie w tokenie: zdegradowany albo
 * usuniety profil traci wladze od razu, a nie po wygasnieciu tokenu.
 */
async function isAdmin(env: Env, claims: AccessClaims): Promise<boolean> {
  if (!claims.profileId) {
    return false;
  }

  const profile = await loadProfile(env, claims.userId, claims.profileId);

  return profile?.role === 'admin';
}

async function adminCount(env: Env, userId: string): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM Profile WHERE userId = ? AND role = 'admin'",
  )
    .bind(userId)
    .first<{ count: number }>();

  return row?.count ?? 0;
}

// --- trasy -------------------------------------------------------------------

/** Lista profili konta: potrzebna na ekranie wyboru, jeszcze przed wejsciem w profil. */
export async function handleListProfiles(env: Env, claims: AccessClaims): Promise<Result> {
  const { results } = await env.DB.prepare(
    `SELECT id, userId, name, color, role, pinHash, permissions, allowedRooms
     FROM Profile WHERE userId = ? ORDER BY createdAt`,
  )
    .bind(claims.userId)
    .all<ProfileRow>();

  return { status: 200, body: { profiles: results.map(publicProfile) } };
}

/**
 * Tworzenie profilu. Pierwszy profil konta jest zawsze administratorem, bez
 * wzgledu na to, co przyslal klient - nie ma wtedy kogo pytac o zgode.
 * Kolejne zaklada wylacznie administrator.
 */
export async function handleCreateProfile(
  env: Env,
  claims: AccessClaims,
  body: Record<string, unknown>,
): Promise<Result> {
  const existing = await env.DB.prepare('SELECT COUNT(*) AS count FROM Profile WHERE userId = ?')
    .bind(claims.userId)
    .first<{ count: number }>();

  const isFirst = (existing?.count ?? 0) === 0;

  if (!isFirst && !(await isAdmin(env, claims))) {
    return fail(403, 'admin_required');
  }

  if ((existing?.count ?? 0) >= MAX_PROFILES) {
    return fail(409, 'too_many_profiles');
  }

  if (!validName(body.name) || !validColor(body.color)) {
    return fail(400, 'invalid_request');
  }

  const role: Role = isFirst ? 'admin' : validRole(body.role) ? body.role : 'member';

  if (body.pin !== undefined && body.pin !== null && !validPin(body.pin)) {
    return fail(400, 'invalid_pin');
  }

  const rooms = parseRooms(body.allowedRooms);

  if (rooms === false) {
    return fail(400, 'invalid_rooms');
  }

  const id = crypto.randomUUID();
  const permissions = normalizePermissions(role, body.permissions);

  await env.DB.prepare(
    `INSERT INTO Profile (id, userId, name, color, role, pinHash, permissions, allowedRooms, createdAt)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      claims.userId,
      body.name.trim(),
      body.color,
      role,
      typeof body.pin === 'string' ? await hashSecret(body.pin) : null,
      JSON.stringify(permissions),
      role === 'admin' || !rooms ? null : JSON.stringify(rooms),
      nowIso(),
    )
    .run();

  const created = await loadProfile(env, claims.userId, id);

  // Pierwszy profil od razu zostaje wybrany na tym urzadzeniu - uzytkownik
  // wlasnie go zalozyl, pytanie o PIN, ktory przed chwila wpisal, byloby absurdem.
  if (isFirst) {
    return {
      status: 201,
      body: { profile: publicProfile(created!), ...(await bindProfile(env, claims, id)) },
    };
  }

  return { status: 201, body: { profile: publicProfile(created!) } };
}

export async function handleUpdateProfile(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  if (!(await isAdmin(env, claims))) {
    return fail(403, 'admin_required');
  }

  const profile = await loadProfile(env, claims.userId, id);

  if (!profile) {
    return fail(404, 'not_found');
  }

  const role: Role = validRole(body.role) ? body.role : profile.role;

  if (body.role !== undefined && !validRole(body.role)) {
    return fail(400, 'invalid_request');
  }

  if (profile.role === 'admin' && role !== 'admin' && (await adminCount(env, claims.userId)) <= 1) {
    return fail(409, 'last_admin');
  }

  const name = body.name === undefined ? profile.name : body.name;
  const color = body.color === undefined ? profile.color : body.color;

  if (!validName(name) || !validColor(color)) {
    return fail(400, 'invalid_request');
  }

  const rooms = parseRooms(body.allowedRooms);

  if (rooms === false) {
    return fail(400, 'invalid_rooms');
  }

  // Zmiana roli bez podanych uprawnien przywraca domyslne nowej roli.
  const permissions = normalizePermissions(
    role,
    body.permissions ?? (role === profile.role ? JSON.parse(profile.permissions) : undefined),
  );

  const allowedRooms =
    role === 'admin'
      ? null
      : rooms === undefined
        ? profile.allowedRooms
        : rooms === null
          ? null
          : JSON.stringify(rooms);

  await env.DB.prepare(
    'UPDATE Profile SET name = ?, color = ?, role = ?, permissions = ?, allowedRooms = ? WHERE id = ?',
  )
    .bind(name.trim(), color, role, JSON.stringify(permissions), allowedRooms, id)
    .run();

  return { status: 200, body: { profile: publicProfile((await loadProfile(env, claims.userId, id))!) } };
}

export async function handleDeleteProfile(
  env: Env,
  claims: AccessClaims,
  id: string,
): Promise<Result> {
  if (!(await isAdmin(env, claims))) {
    return fail(403, 'admin_required');
  }

  const profile = await loadProfile(env, claims.userId, id);

  if (!profile) {
    return fail(404, 'not_found');
  }

  if (profile.role === 'admin' && (await adminCount(env, claims.userId)) <= 1) {
    return fail(409, 'last_admin');
  }

  await env.DB.batch([
    env.DB.prepare('DELETE FROM Profile WHERE id = ?').bind(id),
    env.DB.prepare('DELETE FROM Throttle WHERE key = ?').bind(`pin:${id}`),
  ]);

  return { status: 200, body: { status: 'ok' } };
}

/**
 * Wybor profilu na urzadzeniu. PIN weryfikuje tylko serwer, z blokada po pieciu
 * pomylkach - lokalnie czterocyfrowy kod da sie przeklikac w minute.
 */
export async function handleSelectProfile(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  const profile = await loadProfile(env, claims.userId, id);

  if (!profile) {
    return fail(404, 'not_found');
  }

  if (profile.pinHash) {
    const throttleKey = `pin:${id}`;
    const locked = await lockedUntil(env, throttleKey);

    if (locked) {
      return fail(429, 'locked', { retryAt: locked });
    }

    if (!validPin(body.pin) || !(await verifySecret(body.pin, profile.pinHash))) {
      await recordFailure(env, throttleKey);

      return fail(401, 'invalid_pin');
    }

    await clearFailures(env, throttleKey);
  }

  return {
    status: 200,
    body: { profile: publicProfile(profile), ...(await bindProfile(env, claims, id)) },
  };
}

/**
 * Ustawienie albo usuniecie PIN-u przez administratora - to jest "reset PIN-u
 * przez admina". `pin: null` zdejmuje zabezpieczenie, `pin: "1234"` ustawia nowe.
 * Zadziala takze na profilu, ktorego wlasciciel zapomnial kodu i jest zablokowany.
 */
export async function handleSetPin(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  if (!(await isAdmin(env, claims))) {
    return fail(403, 'admin_required');
  }

  if (!(await loadProfile(env, claims.userId, id))) {
    return fail(404, 'not_found');
  }

  if (body.pin !== null && !validPin(body.pin)) {
    return fail(400, 'invalid_pin');
  }

  await env.DB.prepare('UPDATE Profile SET pinHash = ? WHERE id = ?')
    .bind(body.pin === null ? null : await hashSecret(body.pin as string), id)
    .run();

  await clearFailures(env, `pin:${id}`);

  return { status: 200, body: { status: 'ok' } };
}

/**
 * Wyjscie awaryjne, gdy zapomniany PIN nalezy do jedynego administratora:
 * nikt inny go nie zresetuje. Haslo konta jest wtedy ostatnia instancja -
 * kto je zna, jest wlascicielem domu.
 */
export async function handleRecoverPin(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  if (!(await loadProfile(env, claims.userId, id))) {
    return fail(404, 'not_found');
  }

  const check = await verifyAccountPassword(env, claims.userId, body.password);

  if (typeof check === 'object') {
    return fail(429, 'locked', { retryAt: check.locked });
  }

  if (check === 'wrong') {
    return fail(401, 'invalid_credentials');
  }

  if (body.pin !== undefined && body.pin !== null && !validPin(body.pin)) {
    return fail(400, 'invalid_pin');
  }

  await env.DB.prepare('UPDATE Profile SET pinHash = ? WHERE id = ?')
    .bind(typeof body.pin === 'string' ? await hashSecret(body.pin) : null, id)
    .run();

  await clearFailures(env, `pin:${id}`);

  return { status: 200, body: { status: 'ok' } };
}
