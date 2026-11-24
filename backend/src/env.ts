export interface Env {
  /** Konta, profile domownikow, sesje. */
  DB: D1Database;

  /** Sekret podpisujacy tokeny dostepu. `wrangler secret put JWT_SECRET`. */
  JWT_SECRET: string;

  /** Wysylka kodow na maila. `wrangler secret put RESEND_API_KEY`. */
  RESEND_API_KEY: string;

  MAIL_FROM: string;

  /**
   * Klucz konta serwisowego Firebase (caly plik JSON) do wysylki push przez FCM.
   * `wrangler secret put FCM_SERVICE_ACCOUNT`. Bez niego push jest wylaczony.
   */
  FCM_SERVICE_ACCOUNT?: string;

  /**
   * Tylko lokalnie (`.dev.vars`): zamiast wysylac maila, wypisz kod w logu.
   * Na produkcji zmiennej nie ma, wiec brak klucza Resend konczy sie bledem,
   * a nie cichym wypisaniem kodow do logow.
   */
  DEV_LOG_MAIL?: string;
}
