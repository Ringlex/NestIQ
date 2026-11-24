import 'household_models.dart';

/// Daty cykliczne. Ta sama logika co `backend/src/dates.ts`; oba kody sprawdzają
/// te same wektory testowe (`test/household/recurrence_test.dart`).

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Dodaje [n] jednostek do dnia; dzień miesiąca jest przycinany do jego długości
/// (31 stycznia + 1 miesiąc = 28/29 lutego).
DateTime addInterval(DateTime date, int n, RepeatUnit unit) {
  if (unit == RepeatUnit.day)
    return DateTime(date.year, date.month, date.day + n);
  final total = date.year * 12 +
      (date.month - 1) +
      n * (unit == RepeatUnit.year ? 12 : 1);
  final year = total ~/ 12;
  final month = total % 12 + 1;
  return DateTime(
      year,
      month,
      date.day < _daysInMonth(year, month)
          ? date.day
          : _daysInMonth(year, month));
}

extension ReminderSchedule on Reminder {
  /// Termin, który użytkownik ma teraz przed oczami.
  ///
  /// - Jednorazowe i „po wykonaniu” (filtr, ekspres): zapisany termin; po terminie
  ///   zostaje zaległe, dopóki ktoś nie odhaczy.
  /// - Stałe terminy (urodziny, polisa): toczą się same do najbliższej przyszłej rocznicy,
  ///   więc nie zalegają.
  DateTime effectiveDate(DateTime today) {
    final t = dateOnly(today);
    if (!repeats || anchorAfterDone || !date.isBefore(t)) return date;
    for (var k = 1; k < 5000; k++) {
      final candidate = addInterval(date, k * repeatEvery, repeatUnit);
      if (!candidate.isBefore(t)) return candidate;
    }
    return date;
  }

  bool isOverdue(DateTime today) =>
      !completed && effectiveDate(today).isBefore(dateOnly(today));

  /// Kolejne terminy (łącznie z bieżącym) w przedziale [from, to]; do kalendarza i powiadomień.
  List<DateTime> occurrences(DateTime from, DateTime to, {DateTime? today}) {
    if (completed) return const [];
    final first = effectiveDate(today ?? from);
    final out = <DateTime>[];
    if (!repeats || anchorAfterDone) {
      if (!first.isBefore(dateOnly(from)) && !first.isAfter(dateOnly(to)))
        out.add(first);
      return out;
    }
    for (var k = 0; k < 2000; k++) {
      final d = addInterval(date, k * repeatEvery, repeatUnit);
      if (d.isAfter(dateOnly(to))) break;
      if (!d.isBefore(dateOnly(from))) out.add(d);
    }
    return out;
  }
}
