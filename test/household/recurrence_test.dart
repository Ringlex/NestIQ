import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/household/household_models.dart';
import 'package:nestiq/household/recurrence.dart';

// Wektory te same co w backend/test/dates.test.ts: serwer i aplikacja muszą liczyć terminy identycznie.

DateTime d(String s) => parseDay(s);
String f(DateTime x) => formatDay(x);

Reminder reminder({
  String date = '2026-10-01',
  int every = 0,
  RepeatUnit unit = RepeatUnit.month,
  bool afterDone = false,
  int lead = 0,
  bool completed = false,
  ReminderKind kind = ReminderKind.custom,
}) =>
    Reminder(
      id: 'r',
      ownerProfileId: 'p',
      kind: kind,
      title: 'Test',
      date: d(date),
      repeatEvery: every,
      repeatUnit: unit,
      anchorAfterDone: afterDone,
      leadDays: lead,
      completed: completed,
    );

void main() {
  group('dodawanie interwałów (jak na serwerze)', () {
    test('koniec miesiąca jest przycinany', () {
      expect(
          f(addInterval(d('2026-01-31'), 1, RepeatUnit.month)), '2026-02-28');
      expect(
          f(addInterval(d('2028-01-31'), 1, RepeatUnit.month)), '2028-02-29');
      expect(
          f(addInterval(d('2026-11-30'), 3, RepeatUnit.month)), '2027-02-28');
      expect(f(addInterval(d('2028-02-29'), 1, RepeatUnit.year)), '2029-02-28');
    });

    test('dni, także przez granicę roku i ujemne', () {
      expect(f(addInterval(d('2026-12-31'), 1, RepeatUnit.day)), '2027-01-01');
      expect(f(addInterval(d('2026-03-01'), -1, RepeatUnit.day)), '2026-02-28');
      expect(
          f(addInterval(d('2026-01-15'), -2, RepeatUnit.month)), '2025-11-15');
    });
  });

  group('termin widoczny dla użytkownika', () {
    final today = d('2026-10-27');

    test('urodziny toczą się same do najbliższej rocznicy, nie zalegają', () {
      final birthday = reminder(
          date: '2020-03-14',
          every: 1,
          unit: RepeatUnit.year,
          kind: ReminderKind.birthday);
      expect(f(birthday.effectiveDate(today)), '2027-03-14');
      expect(birthday.isOverdue(today), isFalse);
    });

    test('urodziny dzisiaj to jeszcze dzisiaj, nie za rok', () {
      final birthday =
          reminder(date: '2020-10-27', every: 1, unit: RepeatUnit.year);
      expect(f(birthday.effectiveDate(today)), '2026-10-27');
    });

    test('filtr po terminie jest zaległy, dopóki ktoś go nie wymieni', () {
      final filter = reminder(date: '2026-10-01', every: 3, afterDone: true);
      expect(f(filter.effectiveDate(today)), '2026-10-01');
      expect(filter.isOverdue(today), isTrue);
    });

    test(
        'przypomnienie jednorazowe w przeszłości jest zaległe, a odhaczone nie',
        () {
      expect(reminder(date: '2026-10-01').isOverdue(today), isTrue);
      expect(reminder(date: '2026-10-01', completed: true).isOverdue(today),
          isFalse);
    });

    test('przypomnienie z przyszłą datą nie jest zaległe', () {
      expect(reminder(date: '2026-11-01').isOverdue(today), isFalse);
    });
  });

  group('wystąpienia w przedziale (kalendarz, powiadomienia)', () {
    test('urodziny: jedno w roku', () {
      final r = reminder(date: '2020-03-14', every: 1, unit: RepeatUnit.year);
      expect(
          r
              .occurrences(d('2026-10-27'), d('2028-12-31'),
                  today: d('2026-10-27'))
              .map(f),
          ['2027-03-14', '2028-03-14']);
      // W kalendarzu widać też rocznice z przeszłych miesięcy.
      expect(
          r
              .occurrences(d('2026-01-01'), d('2026-12-31'),
                  today: d('2026-10-27'))
              .map(f),
          ['2026-03-14']);
    });

    test('miesięczny termin na koniec miesiąca nie dryfuje', () {
      final r = reminder(date: '2026-01-31', every: 1);
      final list = r.occurrences(d('2026-01-01'), d('2026-05-31'),
          today: d('2026-01-01'));
      expect(list.map(f), [
        '2026-01-31',
        '2026-02-28',
        '2026-03-31',
        '2026-04-30',
        '2026-05-31'
      ]);
    });

    test('„po wykonaniu” ma jedno wystąpienie: zapisany termin', () {
      final r = reminder(date: '2026-11-15', every: 3, afterDone: true);
      expect(
          r
              .occurrences(d('2026-01-01'), d('2030-01-01'),
                  today: d('2026-10-27'))
              .map(f),
          ['2026-11-15']);
    });

    test('odhaczone jednorazowe nie ma wystąpień', () {
      expect(
          reminder(completed: true)
              .occurrences(d('2026-01-01'), d('2030-01-01')),
          isEmpty);
    });
  });

  group('wydarzenia wielodniowe', () {
    test('obejmują każdy dzień od początku do końca', () {
      final e = CalendarEvent.fromJson({
        'id': 'e',
        'ownerProfileId': 'p',
        'title': 'Urlop',
        'startsAt': '2026-11-20',
        'endsAt': '2026-11-25',
        'allDay': true,
      });
      expect(e.coversDay(d('2026-11-19')), isFalse);
      expect(e.coversDay(d('2026-11-20')), isTrue);
      expect(e.coversDay(d('2026-11-22')), isTrue);
      expect(e.coversDay(d('2026-11-25')), isTrue);
      expect(e.coversDay(d('2026-11-26')), isFalse);
    });

    test('wydarzenie z godziną obejmuje swój dzień', () {
      final e = CalendarEvent.fromJson({
        'id': 'e',
        'ownerProfileId': 'p',
        'title': 'Dentysta',
        'startsAt': '2026-11-05T15:30',
        'allDay': false,
      });
      expect(e.coversDay(d('2026-11-05')), isTrue);
      expect(e.startsAt.hour, 15);
      expect(e.coversDay(d('2026-11-06')), isFalse);
    });
  });
}
