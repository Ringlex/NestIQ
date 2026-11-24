import type { Env } from './env';
import { isExpired, isoIn } from './util';

const MAX_FAILURES = 5;

const LOCK_SECONDS = 15 * 60;

/**
 * Blokada po serii pomylek, na haslo (`login:<email>`) i na PIN (`pin:<id>`).
 *
 * Czterocyfrowy PIN ma dziesiec tysiecy kombinacji, wiec to nie hash go chroni,
 * tylko wlasnie ta blokada: pieciu prob na kwadrans nie da sie przeklikac.
 * Dlatego PIN jest sprawdzany **wylacznie** na serwerze.
 */
export async function lockedUntil(env: Env, key: string): Promise<string | null> {
  const row = await env.DB.prepare('SELECT lockedUntil FROM Throttle WHERE key = ?')
    .bind(key)
    .first<{ lockedUntil: string | null }>();

  if (row?.lockedUntil && !isExpired(row.lockedUntil)) {
    return row.lockedUntil;
  }

  return null;
}

export async function recordFailure(env: Env, key: string): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO Throttle (key, failures) VALUES (?, 1)
     ON CONFLICT(key) DO UPDATE SET failures = failures + 1`,
  )
    .bind(key)
    .run();

  await env.DB.prepare(
    'UPDATE Throttle SET failures = 0, lockedUntil = ? WHERE key = ? AND failures >= ?',
  )
    .bind(isoIn(LOCK_SECONDS), key, MAX_FAILURES)
    .run();
}

export async function clearFailures(env: Env, key: string): Promise<void> {
  await env.DB.prepare('DELETE FROM Throttle WHERE key = ?').bind(key).run();
}
