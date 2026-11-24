import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/household/household_models.dart';
import 'package:nestiq/household/reminder_plan.dart';

DateTime d(String s) => parseDay(s);

Reminder reminder(
  String id, {
  required String date,
  int every = 0,
  RepeatUnit unit = RepeatUnit.month,
  bool afterDone = false,
  int lead = 0,
  bool completed = false,
  String title = 'Test',
}) =>
    Reminder(
      id: id,
      ownerProfileId: 'p',
      kind: ReminderKind.custom,
      title: title,
      date: d(date),
      repeatEvery: every,
      repeatUnit: unit,
      anchorAfterDone: afterDone,
      leadDays: lead,
      completed: completed,
    );

String when(PlannedNotification n) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${formatDay(n.at)} ${two(n.at.hour)}:${two(n.at.minute)}';
}

void main() {
  final now = DateTime(2026, 10, 27, 8, 0);

  test('urodziny: powiadomienie tydzień wcześniej i w dniu urodzin, o 9:00',
      () {
    final plan = planReminderNotifications(
      [
        reminder('b',
            date: '2020-11-10',
            every: 1,
            unit: RepeatUnit.year,
            lead: 7,
            title: 'Urodziny Ani')
      ],
      now: now,
      horizonDays: 30,
    );

    expect(plan.map(when), ['2026-11-03 09:00', '2026-11-10 09:00']);
    expect(plan.first.title, 'Urodziny Ani');
    expect(plan.first.body, startsWith('Za tydzień'));
    expect(plan.last.body, 'Dziś');
  });

  test('przypomnienie bez wyprzedzenia ma tylko powiadomienie w dniu', () {
    final plan = planReminderNotifications([reminder('x', date: '2026-11-02')],
        now: now);
    expect(plan.map(when), ['2026-11-02 09:00']);
  });

  test('wyprzedzenie jednodniowe mówi „Jutro”', () {
    final plan = planReminderNotifications(
        [reminder('x', date: '2026-11-02', lead: 1)],
        now: now);
    expect(plan.first.body, startsWith('Jutro'));
    expect(plan.first.at.day, 1);
  });

  test('powiadomienia z przeszłości są pomijane (wyprzedzenie już minęło)', () {
    // Termin za 3 dni, wyprzedzenie 7 dni: moment wyprzedzenia był 4 dni temu.
    final plan = planReminderNotifications(
        [reminder('x', date: '2026-10-30', lead: 7)],
        now: now);
    expect(plan.map(when), ['2026-10-30 09:00']);
  });

  test('dziś o 9:00, gdy jest już po 9:00, nie planuje się w przeszłości', () {
    final late = DateTime(2026, 10, 27, 10, 0);
    expect(
        planReminderNotifications([reminder('x', date: '2026-10-27')],
            now: late),
        isEmpty);
    expect(
        planReminderNotifications([reminder('x', date: '2026-10-27')], now: now)
            .map(when),
        ['2026-10-27 09:00']);
  });

  test('zaległy filtr dostaje jedno powiadomienie na najbliższy poranek', () {
    final overdue = reminder('f',
        date: '2026-10-01', every: 3, afterDone: true, title: 'Wymiana filtra');
    expect(planReminderNotifications([overdue], now: now).map(when),
        ['2026-10-27 09:00']);
    expect(
        planReminderNotifications([overdue], now: DateTime(2026, 10, 27, 12))
            .map(when),
        ['2026-10-28 09:00']);
    expect(planReminderNotifications([overdue], now: now).single.body,
        startsWith('Zaległe'));
  });

  test('odhaczone jednorazowe nie powiadamia', () {
    expect(
        planReminderNotifications(
            [reminder('x', date: '2026-11-02', completed: true)],
            now: now),
        isEmpty);
  });

  test('cykliczne „od terminu” daje kolejne rocznice', () {
    final plan = planReminderNotifications(
      [
        reminder('p',
            date: '2026-12-15',
            every: 1,
            unit: RepeatUnit.year,
            lead: 30,
            title: 'Polisa')
      ],
      now: now,
      horizonDays: 450,
    );
    expect(plan.map(when), [
      '2026-11-15 09:00',
      '2026-12-15 09:00',
      '2027-11-15 09:00',
      '2027-12-15 09:00',
    ]);
  });

  test('limit zostawia najbliższe w czasie, a wynik jest posortowany', () {
    final many = [
      for (var i = 0; i < 100; i++)
        reminder('r$i', date: formatDay(DateTime(2026, 11, 1 + i % 28, 0))),
    ];
    final plan = planReminderNotifications(many, now: now, limit: 10);
    expect(plan.length, 10);
    expect([...plan]..sort((a, b) => a.at.compareTo(b.at)), plan);
    expect(plan.first.at, DateTime(2026, 11, 1, 9));
  });

  test('numery powiadomień są stałe i różne dla różnych terminów', () {
    final r = reminder('r', date: '2026-11-02', lead: 1);
    final a = planReminderNotifications([r], now: now);
    final b = planReminderNotifications([r], now: now);
    expect(a.map((n) => n.id), b.map((n) => n.id));
    expect(a.map((n) => n.id).toSet().length, a.length);
    expect(stableId('abc'), stableId('abc'));
    expect(stableId('abc'), isNot(stableId('abd')));
    expect(stableId('x'), lessThan(0x80000000));
  });
}
