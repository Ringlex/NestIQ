import 'household_models.dart';
import 'recurrence.dart';

/// Jedno zaplanowane powiadomienie o przypomnieniu.
class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    this.payload = reminderPayload,
  });

  final int id;
  final DateTime at;
  final String title;
  final String body;
  final String payload;

  @override
  String toString() => '$at $title — $body';
}

const reminderPayload = 'planner:reminders';

/// FNV-1a: stały numer powiadomienia, taki sam przy każdym uruchomieniu (w odróżnieniu od `hashCode`).
int stableId(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

String _leadText(int days) => switch (days) {
      1 => 'Jutro',
      7 => 'Za tydzień',
      _ => 'Za $days dni',
    };

/// Kiedy i jakie powiadomienia pokazać.
///
/// Dla każdego terminu: przypomnienie z wyprzedzeniem ([Reminder.leadDays] dni wcześniej)
/// oraz w samym dniu, o [hour]. Zaległe zadania (filtr po terminie) dostają jedno
/// powiadomienie na najbliższy poranek. Zwracamy co najwyżej [limit] najbliższych, bo
/// systemy ograniczają liczbę zaplanowanych powiadomień (iOS: 64).
List<PlannedNotification> planReminderNotifications(
  List<Reminder> reminders, {
  required DateTime now,
  int hour = 9,
  int horizonDays = 400,
  int limit = 50,
}) {
  final today = dateOnly(now);
  final horizon = addInterval(today, horizonDays, RepeatUnit.day);
  final plan = <PlannedNotification>[];

  PlannedNotification? at(Reminder r, DateTime day, String prefix, String key) {
    final when = DateTime(day.year, day.month, day.day, hour);
    if (!when.isAfter(now)) return null;
    return PlannedNotification(
      id: stableId('${r.id}:${formatDay(day)}:$key'),
      at: when,
      title: r.title,
      body: prefix,
    );
  }

  for (final r in reminders) {
    if (r.completed) continue;

    if (r.isOverdue(today)) {
      final morning =
          DateTime(today.year, today.month, today.day, hour).isAfter(now)
              ? today
              : addInterval(today, 1, RepeatUnit.day);
      final n = at(
          r,
          morning,
          'Zaległe: minął termin ${formatDay(r.effectiveDate(today))}',
          'overdue');
      if (n != null) plan.add(n);
      continue;
    }

    for (final due in r.occurrences(today, horizon, today: today)) {
      if (r.leadDays > 0) {
        final lead = at(r, addInterval(due, -r.leadDays, RepeatUnit.day),
            '${_leadText(r.leadDays)}: ${formatDay(due)}', 'lead');
        if (lead != null) plan.add(lead);
      }
      final onDay = at(r, due, 'Dziś', 'day');
      if (onDay != null) plan.add(onDay);
    }
  }

  plan.sort((a, b) => a.at.compareTo(b.at));
  return plan.take(limit).toList();
}
