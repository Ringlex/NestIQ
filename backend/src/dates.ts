/**
 * Daty kalendarzowe (YYYY-MM-DD) bez stref czasowych: przypomnienia dotycza
 * dni w domu uzytkownika, a nie chwil na osi czasu.
 *
 * Plik nie ma zadnych importow, zeby dalo sie go testowac samym Node.
 * Te same wektory testowe sprawdza klient we Flutterze (test/household/).
 */

export type RepeatUnit = 'day' | 'month' | 'year';

export function isDate(value: unknown): value is string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }

  const [y, m, d] = value.split('-').map(Number) as [number, number, number];
  const parsed = new Date(Date.UTC(y, m - 1, d));

  return parsed.getUTCFullYear() === y && parsed.getUTCMonth() === m - 1 && parsed.getUTCDate() === d;
}

/** YYYY-MM-DD albo YYYY-MM-DDTHH:MM (czas lokalny domu). */
export function isDateTime(value: unknown): value is string {
  if (typeof value !== 'string') {
    return false;
  }

  if (isDate(value)) {
    return true;
  }

  const match = /^(\d{4}-\d{2}-\d{2})T([01]\d|2[0-3]):([0-5]\d)$/.exec(value);

  return match !== null && isDate(match[1]);
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

function format(year: number, month: number, day: number): string {
  return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

/** Dodaje [n] jednostek do daty; dzien jest przycinany do dlugosci miesiaca (31 sty + 1 mies. = 28/29 lut.). */
export function addInterval(date: string, n: number, unit: RepeatUnit): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number];

  if (unit === 'day') {
    const moved = new Date(Date.UTC(y, m - 1, d + n));

    return format(moved.getUTCFullYear(), moved.getUTCMonth() + 1, moved.getUTCDate());
  }

  const total = y * 12 + (m - 1) + n * (unit === 'year' ? 12 : 1);
  const year = Math.floor(total / 12);
  const month = (total % 12) + 1;

  return format(year, month, Math.min(d, daysInMonth(year, month)));
}

export interface Recurrence {
  date: string;
  repeatEvery: number;
  repeatUnit: RepeatUnit;
  anchor: 'fixed' | 'afterDone';
}

/**
 * Kolejny termin po wykonaniu. `null` dla przypomnienia jednorazowego.
 *
 * - `afterDone`: od dnia wykonania (filtr wymieniony dzis -> kolejny za N miesiecy).
 * - `fixed`: od ustalonego terminu, pierwszy po dniu wykonania. Liczymy zawsze od
 *   pierwotnej daty (k * interwal), zeby przyciecie do konca miesiaca nie przesuwalo
 *   terminu na stale (31 sty -> 28 lut. -> 28 mar. zamiast 31 mar.).
 */
export function nextDue(rec: Recurrence, doneOn: string): string | null {
  if (rec.repeatEvery <= 0) {
    return null;
  }

  if (rec.anchor === 'afterDone') {
    return addInterval(doneOn, rec.repeatEvery, rec.repeatUnit);
  }

  for (let k = 1; k < 5000; k += 1) {
    const candidate = addInterval(rec.date, k * rec.repeatEvery, rec.repeatUnit);

    if (candidate > doneOn) {
      return candidate;
    }
  }

  return null;
}

/** Dzien powiadomienia: [leadDays] dni przed terminem. */
export function reminderDay(date: string, leadDays: number): string {
  return addInterval(date, -leadDays, 'day');
}
