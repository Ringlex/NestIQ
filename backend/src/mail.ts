import type { Env } from './env';
import { isExpired, isoIn, nowIso, randomCode, sha256, timingSafeEqual } from './util';

export type CodePurpose = 'verify' | 'reset';

const CODE_TTL_SECONDS = 10 * 60;

/** Minuta przerwy miedzy kodami na ten sam adres i cel. */
const CODE_COOLDOWN_SECONDS = 60;

/** Piec prob na kod. Potem trzeba poprosic o nowy. */
const MAX_CODE_ATTEMPTS = 5;

const SUBJECTS: Record<CodePurpose, (code: string) => string> = {
  verify: (code) => `${code} - kod potwierdzajacy konto NestIQ`,
  reset: (code) => `${code} - kod do zmiany hasla w NestIQ`,
};

const BODIES: Record<CodePurpose, (code: string) => string> = {
  verify: (code) =>
    `Twoj kod potwierdzajacy konto NestIQ: ${code}\n\nKod wygasa za 10 minut.\nJesli to nie Ty zakladales konto, zignoruj te wiadomosc.`,
  reset: (code) =>
    `Twoj kod do zmiany hasla w NestIQ: ${code}\n\nKod wygasa za 10 minut.\nJesli to nie Ty prosiles o zmiane hasla, zignoruj te wiadomosc - haslo zostaje bez zmian.`,
};

async function sendMail(env: Env, to: string, subject: string, text: string): Promise<boolean> {
  if (env.DEV_LOG_MAIL === 'true') {
    console.log(`[mail] do ${to}: ${subject}\n${text}`);

    return true;
  }

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${env.RESEND_API_KEY}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ from: env.MAIL_FROM, to, subject, text }),
  });

  return response.ok;
}

/**
 * Wysyla nowy kod. `false` oznacza "za wczesnie" (cooldown) albo blad poczty -
 * wolajacy decyduje, czy powiedziec o tym uzytkownikowi (potwierdzenie konta)
 * czy milczec (reset hasla, zeby nie zdradzac, kto ma konto).
 */
export async function issueCode(
  env: Env,
  email: string,
  purpose: CodePurpose,
): Promise<'sent' | 'cooldown' | 'mail_failed'> {
  const previous = await env.DB.prepare(
    'SELECT sentAt FROM EmailCode WHERE email = ? AND purpose = ?',
  )
    .bind(email, purpose)
    .first<{ sentAt: string }>();

  if (previous && Date.parse(previous.sentAt) + CODE_COOLDOWN_SECONDS * 1000 > Date.now()) {
    return 'cooldown';
  }

  const code = randomCode();

  await env.DB.prepare(
    `INSERT INTO EmailCode (email, purpose, codeHash, expiresAt, attempts, sentAt)
     VALUES (?, ?, ?, ?, 0, ?)
     ON CONFLICT(email, purpose) DO UPDATE SET
       codeHash = excluded.codeHash, expiresAt = excluded.expiresAt,
       attempts = 0, sentAt = excluded.sentAt`,
  )
    .bind(email, purpose, await sha256(`${email}:${purpose}:${code}`), isoIn(CODE_TTL_SECONDS), nowIso())
    .run();

  const sent = await sendMail(env, email, SUBJECTS[purpose](code), BODIES[purpose](code));

  return sent ? 'sent' : 'mail_failed';
}

/** Sprawdza kod i - gdy pasuje - zuzywa go. Pomylka liczy sie do limitu prob. */
export async function consumeCode(
  env: Env,
  email: string,
  purpose: CodePurpose,
  code: string,
): Promise<boolean> {
  const stored = await env.DB.prepare(
    'SELECT codeHash, expiresAt, attempts FROM EmailCode WHERE email = ? AND purpose = ?',
  )
    .bind(email, purpose)
    .first<{ codeHash: string; expiresAt: string; attempts: number }>();

  if (!stored || isExpired(stored.expiresAt) || stored.attempts >= MAX_CODE_ATTEMPTS) {
    return false;
  }

  await env.DB.prepare('UPDATE EmailCode SET attempts = attempts + 1 WHERE email = ? AND purpose = ?')
    .bind(email, purpose)
    .run();

  const matches = timingSafeEqual(stored.codeHash, await sha256(`${email}:${purpose}:${code}`));

  if (matches) {
    await env.DB.prepare('DELETE FROM EmailCode WHERE email = ? AND purpose = ?')
      .bind(email, purpose)
      .run();
  }

  return matches;
}
