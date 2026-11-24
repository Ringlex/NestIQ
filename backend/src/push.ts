import type { AccessClaims } from './auth';
import type { Env } from './env';
import { fail, nowIso, type Result } from './util';

/**
 * Powiadomienia push przez Firebase Cloud Messaging (HTTP v1).
 *
 * Klucz konta serwisowego Firebase siedzi w sekrecie `FCM_SERVICE_ACCOUNT`. Bez niego
 * wysylka jest po cichu pomijana: wiadomosci nadal dzialaja, tylko bez push.
 */

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const MAX_TOKEN = 4096;

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

function readAccount(env: Env): ServiceAccount | null {
  if (!env.FCM_SERVICE_ACCOUNT) {
    return null;
  }

  try {
    const parsed = JSON.parse(env.FCM_SERVICE_ACCOUNT) as Partial<ServiceAccount>;

    return parsed.project_id && parsed.client_email && parsed.private_key ? (parsed as ServiceAccount) : null;
  } catch {
    return null;
  }
}

function base64Url(input: ArrayBuffer | string): string {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : new Uint8Array(input);
  let binary = '';

  for (const b of bytes) {
    binary += String.fromCharCode(b);
  }

  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function signJwt(account: ServiceAccount): Promise<string> {
  const pem = account.private_key.replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${base64Url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${base64Url(
    JSON.stringify({
      iss: account.client_email,
      scope: SCOPE,
      aud: account.token_uri ?? 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  )}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));

  return `${unsigned}.${base64Url(signature)}`;
}

let cached: { token: string; expiresAt: number } | null = null;

async function accessToken(account: ServiceAccount): Promise<string | null> {
  if (cached && cached.expiresAt > Date.now() + 60_000) {
    return cached.token;
  }

  const response = await fetch(account.token_uri ?? 'https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: await signJwt(account),
    }),
  });

  if (!response.ok) {
    return null;
  }

  const data = (await response.json()) as { access_token?: string; expires_in?: number };

  if (!data.access_token) {
    return null;
  }

  cached = { token: data.access_token, expiresAt: Date.now() + (data.expires_in ?? 3600) * 1000 };

  return cached.token;
}

export async function handleRegisterPush(env: Env, claims: AccessClaims, body: Record<string, unknown>): Promise<Result> {
  const { token, platform } = body;

  if (typeof token !== 'string' || token.length < 20 || token.length > MAX_TOKEN) {
    return fail(400, 'invalid_request');
  }

  if (platform !== 'android' && platform !== 'ios') {
    return fail(400, 'invalid_request');
  }

  // Ten sam token moze przejsc na inne konto (sprzedany telefon), wiec nadpisujemy wlasciciela.
  await env.DB.prepare(
    `INSERT INTO PushToken (token, userId, familyId, platform, updatedAt) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(token) DO UPDATE SET userId = excluded.userId, familyId = excluded.familyId,
       platform = excluded.platform, updatedAt = excluded.updatedAt`,
  )
    .bind(token, claims.userId, claims.familyId, platform, nowIso())
    .run();

  return { status: 200, body: { status: 'ok' } };
}

export async function handleUnregisterPush(env: Env, claims: AccessClaims, body: Record<string, unknown>): Promise<Result> {
  if (typeof body.token === 'string') {
    await env.DB.prepare('DELETE FROM PushToken WHERE token = ? AND userId = ?').bind(body.token, claims.userId).run();
  }

  return { status: 200, body: { status: 'ok' } };
}

/**
 * Tokeny urzadzen, na ktorych aktualnie zalogowany jest ktorykolwiek z podanych profili
 * (`profileIds`) albo, gdy `null`, kazdy profil poza `exceptProfileId`.
 */
async function tokensFor(
  env: Env,
  userId: string,
  recipient: string | null,
  exceptProfileId: string,
): Promise<string[]> {
  const where = recipient ? 'r.profileId = ?' : 'r.profileId IS NOT NULL AND r.profileId != ?';
  const { results } = await env.DB.prepare(
    `SELECT DISTINCT p.token FROM PushToken p
       JOIN RefreshToken r ON r.familyId = p.familyId AND r.usedAt IS NULL AND r.expiresAt > ?
      WHERE p.userId = ? AND ${where}`,
  )
    .bind(nowIso(), userId, recipient ?? exceptProfileId)
    .all<{ token: string }>();

  return results.map((row) => row.token);
}

export interface PushMessage {
  title: string;
  body: string;
  channel: string;
  data?: Record<string, string>;
}

/** Wysyla push do domownikow; bledy sieci nie moga psuc wysylki samej wiadomosci. */
export async function pushToHousehold(
  env: Env,
  userId: string,
  recipient: string | null,
  exceptProfileId: string,
  message: PushMessage,
): Promise<void> {
  const account = readAccount(env);

  if (!account) {
    return;
  }

  try {
    const tokens = await tokensFor(env, userId, recipient, exceptProfileId);

    if (tokens.length === 0) {
      return;
    }

    const bearer = await accessToken(account);

    if (!bearer) {
      return;
    }

    await Promise.all(
      tokens.map(async (token) => {
        const response = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
          method: 'POST',
          headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: message.title, body: message.body },
              data: message.data ?? {},
              android: { priority: 'HIGH', notification: { channel_id: message.channel } },
              apns: { payload: { aps: { sound: 'default' } } },
            },
          }),
        });

        // Token po odinstalowaniu aplikacji przestaje istniec: sprzatamy, zeby nie wysylac w nieskonczonosc.
        if (response.status === 404 || response.status === 400) {
          const error = (await response.text()).toUpperCase();

          if (error.includes('UNREGISTERED') || error.includes('INVALID_ARGUMENT')) {
            await env.DB.prepare('DELETE FROM PushToken WHERE token = ?').bind(token).run();
          }
        }
      }),
    );
  } catch {
    // Push jest dodatkiem do wiadomosci, nie jej warunkiem.
  }
}
