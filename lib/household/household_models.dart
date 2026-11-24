// Modele planera domowego: listy zakupów, przypomnienia, kalendarz, wiadomości.
// Daty bez godziny to dni kalendarzowe w czasie lokalnym (patrz `recurrence.dart`).

DateTime parseDay(String value) {
  final p = value.substring(0, 10).split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

String formatDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// --------------------------------------------------------------- listy zakupów

class PlannerItem {
  const PlannerItem({
    required this.id,
    required this.text,
    required this.checked,
    this.quantity,
    this.checkedBy,
    this.addedBy,
    this.position = 0,
  });

  factory PlannerItem.fromJson(Map<String, dynamic> json) => PlannerItem(
        id: json['id'] as String,
        text: json['text'] as String,
        quantity: json['quantity'] as String?,
        checked: json['checked'] == true,
        checkedBy: json['checkedBy'] as String?,
        addedBy: json['addedBy'] as String?,
        position: (json['position'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String text;
  final String? quantity;
  final bool checked;
  final String? checkedBy;
  final String? addedBy;
  final int position;

  PlannerItem copyWith(
          {bool? checked, String? checkedBy, bool clearCheckedBy = false}) =>
      PlannerItem(
        id: id,
        text: text,
        quantity: quantity,
        checked: checked ?? this.checked,
        checkedBy: clearCheckedBy ? null : (checkedBy ?? this.checkedBy),
        addedBy: addedBy,
        position: position,
      );
}

class PlannerList {
  const PlannerList({
    required this.id,
    required this.name,
    required this.ownerProfileId,
    required this.sharedWith,
    required this.items,
  });

  factory PlannerList.fromJson(Map<String, dynamic> json) => PlannerList(
        id: json['id'] as String,
        name: json['name'] as String,
        ownerProfileId: json['ownerProfileId'] as String,
        sharedWith: ((json['sharedWith'] as List?) ?? const []).cast<String>(),
        items: [
          for (final i in (json['items'] as List? ?? const []))
            PlannerItem.fromJson((i as Map).cast<String, dynamic>()),
        ],
      );

  final String id;
  final String name;
  final String ownerProfileId;
  final List<String> sharedWith;
  final List<PlannerItem> items;

  int get openCount => items.where((i) => !i.checked).length;

  PlannerList copyWith(
          {String? name, List<String>? sharedWith, List<PlannerItem>? items}) =>
      PlannerList(
        id: id,
        name: name ?? this.name,
        ownerProfileId: ownerProfileId,
        sharedWith: sharedWith ?? this.sharedWith,
        items: items ?? this.items,
      );
}

// --------------------------------------------------------------- przypomnienia

enum RepeatUnit {
  day('day', 'dni'),
  month('month', 'miesięcy'),
  year('year', 'lat');

  const RepeatUnit(this.wire, this.label);
  final String wire;
  final String label;

  static RepeatUnit fromWire(String? v) =>
      values.firstWhere((u) => u.wire == v, orElse: () => RepeatUnit.month);
}

enum ReminderKind {
  waterFilter('water_filter', 'Filtr do wody'),
  coffeeClean('coffee_clean', 'Ekspres do kawy'),
  insurance('insurance', 'Ubezpieczenie'),
  birthday('birthday', 'Urodziny'),
  custom('custom', 'Inne');

  const ReminderKind(this.wire, this.label);
  final String wire;
  final String label;

  static ReminderKind fromWire(String? v) =>
      values.firstWhere((k) => k.wire == v, orElse: () => ReminderKind.custom);
}

class Reminder {
  const Reminder({
    required this.id,
    required this.ownerProfileId,
    required this.kind,
    required this.title,
    required this.date,
    this.note,
    this.repeatEvery = 0,
    this.repeatUnit = RepeatUnit.month,
    this.anchorAfterDone = false,
    this.leadDays = 0,
    this.shared = true,
    this.completed = false,
  });

  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
        id: json['id'] as String,
        ownerProfileId: json['ownerProfileId'] as String,
        kind: ReminderKind.fromWire(json['kind'] as String?),
        title: json['title'] as String,
        note: json['note'] as String?,
        date: parseDay(json['date'] as String),
        repeatEvery: (json['repeatEvery'] as num?)?.toInt() ?? 0,
        repeatUnit: RepeatUnit.fromWire(json['repeatUnit'] as String?),
        anchorAfterDone: json['anchor'] == 'afterDone',
        leadDays: (json['leadDays'] as num?)?.toInt() ?? 0,
        shared: json['shared'] != false,
        completed: json['completedAt'] != null,
      );

  final String id;
  final String ownerProfileId;
  final ReminderKind kind;
  final String title;
  final String? note;

  /// Najbliższy termin zapisany w bazie (dla cyklicznych „od terminu” może być już w przeszłości).
  final DateTime date;
  final int repeatEvery;
  final RepeatUnit repeatUnit;

  /// `true`: kolejny termin liczony od dnia wykonania (filtr, ekspres);
  /// `false`: od ustalonego terminu (urodziny, polisa).
  final bool anchorAfterDone;
  final int leadDays;
  final bool shared;
  final bool completed;

  bool get repeats => repeatEvery > 0;

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        'title': title,
        'note': note,
        'date': formatDay(date),
        'repeatEvery': repeatEvery,
        'repeatUnit': repeatUnit.wire,
        'anchor': anchorAfterDone ? 'afterDone' : 'fixed',
        'leadDays': leadDays,
        'shared': shared,
      };
}

// --------------------------------------------------------------- kalendarz

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.ownerProfileId,
    required this.title,
    required this.startsAt,
    required this.allDay,
    this.note,
    this.endsAt,
    this.shared = true,
  });

  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    DateTime parse(String v) => v.length > 10 ? DateTime.parse(v) : parseDay(v);
    return CalendarEvent(
      id: json['id'] as String,
      ownerProfileId: json['ownerProfileId'] as String,
      title: json['title'] as String,
      note: json['note'] as String?,
      startsAt: parse(json['startsAt'] as String),
      endsAt: json['endsAt'] == null ? null : parse(json['endsAt'] as String),
      allDay: json['allDay'] == true,
      shared: json['shared'] != false,
    );
  }

  final String id;
  final String ownerProfileId;
  final String title;
  final String? note;
  final DateTime startsAt;
  final DateTime? endsAt;
  final bool allDay;
  final bool shared;

  /// Czy wydarzenie obejmuje podany dzień (także wielodniowe).
  bool coversDay(DateTime day) {
    final d = dateOnly(day);
    final start = dateOnly(startsAt);
    final end = dateOnly(endsAt ?? startsAt);
    return !d.isBefore(start) && !d.isAfter(end);
  }
}

// --------------------------------------------------------------- wiadomości

class PlannerMessage {
  const PlannerMessage({
    required this.id,
    required this.from,
    required this.body,
    required this.createdAt,
    required this.read,
    this.to,
  });

  factory PlannerMessage.fromJson(Map<String, dynamic> json) => PlannerMessage(
        id: json['id'] as String,
        from: json['from'] as String,
        to: json['to'] as String?,
        body: json['body'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
        read: json['read'] == true,
      );

  final String id;
  final String from;

  /// `null` = do wszystkich profili.
  final String? to;
  final String body;
  final DateTime createdAt;
  final bool read;
}
