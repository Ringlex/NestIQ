import assert from 'node:assert/strict';
import { test } from 'node:test';

import { addInterval, isDate, isDateTime, nextDue, reminderDay } from '../src/dates.ts';

test('poprawne i niepoprawne daty', () => {
  assert.equal(isDate('2026-02-28'), true);
  assert.equal(isDate('2026-02-29'), false, '2026 nie jest przestepny');
  assert.equal(isDate('2028-02-29'), true);
  assert.equal(isDate('2026-13-01'), false);
  assert.equal(isDate('2026-1-1'), false);
  assert.equal(isDate(20260101), false);
  assert.equal(isDateTime('2026-10-27T09:30'), true);
  assert.equal(isDateTime('2026-10-27T24:00'), false);
  assert.equal(isDateTime('2026-10-27'), true);
});

test('dodawanie dni, miesiecy i lat z przycinaniem konca miesiaca', () => {
  assert.equal(addInterval('2026-01-31', 1, 'month'), '2026-02-28');
  assert.equal(addInterval('2028-01-31', 1, 'month'), '2028-02-29');
  assert.equal(addInterval('2026-11-30', 3, 'month'), '2027-02-28');
  assert.equal(addInterval('2028-02-29', 1, 'year'), '2029-02-28');
  assert.equal(addInterval('2026-12-31', 1, 'day'), '2027-01-01');
  assert.equal(addInterval('2026-03-01', -1, 'day'), '2026-02-28');
  assert.equal(addInterval('2026-01-15', -2, 'month'), '2025-11-15');
});

test('przypomnienie po wykonaniu liczone od dnia wykonania (filtr, ekspres)', () => {
  const filter = { date: '2026-10-01', repeatEvery: 3, repeatUnit: 'month' as const, anchor: 'afterDone' as const };
  assert.equal(nextDue(filter, '2026-10-27'), '2027-01-27', 'wymiana z opoznieniem przesuwa kolejny termin');
});

test('przypomnienie stale liczone od terminu (urodziny, polisa)', () => {
  const birthday = { date: '2026-03-14', repeatEvery: 1, repeatUnit: 'year' as const, anchor: 'fixed' as const };
  assert.equal(nextDue(birthday, '2026-03-14'), '2027-03-14');
  assert.equal(nextDue(birthday, '2026-03-20'), '2027-03-14', 'spoznione odhaczenie nie zmienia dnia urodzin');
  assert.equal(nextDue(birthday, '2028-01-01'), '2028-03-14', 'po kilku latach zaleglosci bierzemy pierwszy przyszly');
});

test('termin na koniec miesiaca nie dryfuje przy kolejnych cyklach', () => {
  const monthly = { date: '2026-01-31', repeatEvery: 1, repeatUnit: 'month' as const, anchor: 'fixed' as const };
  assert.equal(nextDue(monthly, '2026-01-31'), '2026-02-28');
  assert.equal(nextDue(monthly, '2026-02-28'), '2026-03-31', 'wraca na 31, a nie zostaje na 28');
});

test('przypomnienie jednorazowe nie ma kolejnego terminu', () => {
  const once = { date: '2026-10-01', repeatEvery: 0, repeatUnit: 'month' as const, anchor: 'fixed' as const };
  assert.equal(nextDue(once, '2026-10-02'), null);
});

test('dzien powiadomienia z wyprzedzeniem', () => {
  assert.equal(reminderDay('2026-03-14', 7), '2026-03-07', 'urodziny z tygodniowym wyprzedzeniem');
  assert.equal(reminderDay('2026-03-03', 7), '2026-02-24');
  assert.equal(reminderDay('2026-03-14', 0), '2026-03-14');
});
