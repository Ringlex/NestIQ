import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../household/household_controller.dart';
import '../../household/household_models.dart';
import '../../household/recurrence.dart';
import 'planner_common.dart';
import 'reminders_tab.dart' show reminderIcon;

/// Poniedziałek tygodnia, w którym jest [day].
DateTime weekStart(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - 1));

/// Zakres widocznej siatki miesiąca: od poniedziałku do niedzieli.
(DateTime, DateTime) gridRange(DateTime month) {
  final first = weekStart(DateTime(month.year, month.month, 1));
  final last = DateTime(month.year, month.month + 1, 0);
  final end = DateTime(last.year, last.month, last.day + (7 - last.weekday));
  return (first, end);
}

class CalendarTab extends StatefulWidget {
  const CalendarTab(
      {super.key,
      required this.household,
      required this.account,
      DateTime Function()? clock})
      : _clock = clock;

  final HouseholdController household;
  final AccountController account;
  final DateTime Function()? _clock;

  @override
  State<CalendarTab> createState() => _CalendarTabState();
}

class _CalendarTabState extends State<CalendarTab> {
  late final DateTime _today =
      dateOnly(widget._clock?.call() ?? DateTime.now());
  late DateTime _month = DateTime(_today.year, _today.month);
  late DateTime _selected = _today;

  HouseholdController get _h => widget.household;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (from, to) = gridRange(_month);
    try {
      await _h.loadEvents(from, to);
    } catch (_) {
      // Błąd pokaże kontroler (`error`); kalendarz działa dalej na tym, co ma.
    }
  }

  void _shift(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _selected = DateTime(_month.year, _month.month, 1);
      if (_selected.year == _today.year && _selected.month == _today.month)
        _selected = _today;
    });
    _load();
  }

  Set<DateTime> _marked(DateTime from, DateTime to) {
    final days = <DateTime>{};
    for (final e in _h.events) {
      for (var d = from;
          !d.isAfter(to);
          d = DateTime(d.year, d.month, d.day + 1)) {
        if (e.coversDay(d)) days.add(d);
      }
    }
    for (final r in _h.reminders) {
      days.addAll(r.occurrences(from, to, today: _today));
    }
    return days;
  }

  Future<void> _editEvent(CalendarEvent? event) async {
    final result = await showModalBottomSheet<_EventResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => EventEditor(event: event, day: _selected),
    );
    if (result == null || !mounted) return;
    final (from, to) = gridRange(_month);
    final ok = await guarded(context, () async {
      if (result.delete) {
        await _h.deleteEvent(event!.id);
      } else if (event == null) {
        await _h.createEvent(
            title: result.title!,
            startsAt: result.start!,
            endsAt: result.end,
            allDay: result.allDay,
            note: result.note,
            shared: result.shared);
      } else {
        await _h.updateEvent(event.id,
            title: result.title!,
            startsAt: result.start!,
            endsAt: result.end,
            allDay: result.allDay,
            note: result.note,
            shared: result.shared);
      }
    });
    if (ok) await _h.loadEvents(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (from, to) = gridRange(_month);
    final weeks = (to.difference(from).inDays + 1) ~/ 7;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _editEvent(null),
        icon: const Icon(Icons.event_available_outlined),
        label: const Text('Wydarzenie'),
      ),
      body: ListenableBuilder(
        listenable: _h,
        builder: (context, _) {
          final marked = _marked(from, to);

          final dayEvents = [
            for (final e in _h.events)
              if (e.coversDay(_selected)) e
          ]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
          final dayReminders = [
            for (final r in _h.reminders)
              if (r.occurrences(_selected, _selected, today: _today).isNotEmpty)
                r,
          ];

          final calendar = <Widget>[
            Row(
              children: [
                IconButton(
                    tooltip: 'Poprzedni miesiąc',
                    onPressed: () => _shift(-1),
                    icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: Text('${monthNames[_month.month - 1]} ${_month.year}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium),
                ),
                IconButton(
                    tooltip: 'Następny miesiąc',
                    onPressed: () => _shift(1),
                    icon: const Icon(Icons.chevron_right)),
              ],
            ),
            Row(
              children: [
                for (final w in weekdayShort)
                  Expanded(
                    child: Center(
                      child: Text(w,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var w = 0; w < weeks; w++)
              Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: _DayCell(
                        day: DateTime(
                            from.year, from.month, from.day + w * 7 + i),
                        inMonth: DateTime(
                                    from.year, from.month, from.day + w * 7 + i)
                                .month ==
                            _month.month,
                        isToday: DateTime(
                                from.year, from.month, from.day + w * 7 + i) ==
                            _today,
                        selected: DateTime(
                                from.year, from.month, from.day + w * 7 + i) ==
                            _selected,
                        marked: marked.contains(DateTime(
                            from.year, from.month, from.day + w * 7 + i)),
                        onTap: (d) => setState(() => _selected = d),
                      ),
                    ),
                ],
              ),
          ];
          final agenda = <Widget>[
            Text(dayLabel(_selected, now: _today),
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (dayEvents.isEmpty && dayReminders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('Nic tego dnia.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            for (final e in dayEvents)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.event_outlined),
                  title: Text(e.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    e.allDay ? 'Cały dzień' : timeLabel(e.startsAt),
                    widget.account.profiles
                            .where((p) => p.id == e.ownerProfileId)
                            .firstOrNull
                            ?.name ??
                        '',
                    if (!e.shared) 'prywatne',
                  ].where((s) => s.isNotEmpty).join(' · ')),
                  onTap: () => _editEvent(e),
                ),
              ),
            for (final r in dayReminders)
              Card(
                child: ListTile(
                  leading: Icon(reminderIcon(r.kind)),
                  title: Text(r.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: const Text('Przypomnienie'),
                ),
              ),
          ];
          // Na szerokim ekranie kalendarz i plan dnia stoją obok siebie.
          return LayoutBuilder(
            builder: (context, box) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: box.maxWidth >= 760
                  ? [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: Column(children: calendar)),
                          const SizedBox(width: 24),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: agenda,
                            ),
                          ),
                        ],
                      ),
                    ]
                  : [...calendar, const SizedBox(height: 16), ...agenda],
            ),
          );
        },
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.selected,
    required this.marked,
    required this.onTap,
  });

  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool selected;
  final bool marked;
  final void Function(DateTime) onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected
        ? scheme.onPrimary
        : inMonth
            ? scheme.onSurface
            : scheme.onSurfaceVariant.withOpacity(0.5);
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${day.day} ${monthGenitive[day.month - 1]}${marked ? ', są wpisy' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onTap(day),
        child: SizedBox(
          height: 48,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : null,
                shape: BoxShape.circle,
                border: isToday && !selected
                    ? Border.all(color: scheme.primary)
                    : null,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Skala tekstu nie może rozpychać stałego kółka dnia.
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('${day.day}',
                          style: TextStyle(
                              color: fg,
                              fontWeight: isToday ? FontWeight.w700 : null)),
                    ),
                  ),
                  Positioned(
                    bottom: 5,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: marked
                            ? (selected ? scheme.onPrimary : scheme.tertiary)
                            : Colors.transparent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EventResult {
  const _EventResult.save({
    required String this.title,
    required DateTime this.start,
    this.end,
    required this.allDay,
    this.note,
    required this.shared,
  }) : delete = false;
  const _EventResult.remove()
      : title = null,
        start = null,
        end = null,
        allDay = true,
        note = null,
        shared = true,
        delete = true;

  final String? title;
  final DateTime? start;
  final DateTime? end;
  final bool allDay;
  final String? note;
  final bool shared;
  final bool delete;
}

class EventEditor extends StatefulWidget {
  const EventEditor({super.key, required this.event, required this.day});

  final CalendarEvent? event;
  final DateTime day;

  @override
  State<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<EventEditor> {
  late final _title = TextEditingController(text: widget.event?.title ?? '');
  late final _note = TextEditingController(text: widget.event?.note ?? '');
  late bool _allDay = widget.event?.allDay ?? false;
  late bool _shared = widget.event?.shared ?? true;
  late DateTime _start = widget.event?.startsAt ??
      DateTime(widget.day.year, widget.day.month, widget.day.day, 18);
  late DateTime? _end = widget.event?.endsAt;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().isNotEmpty &&
      (_end == null || !_end!.isBefore(_start));

  Future<void> _pickDay(bool end) async {
    final current = end ? (_end ?? _start) : _start;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      final merged = DateTime(
          picked.year, picked.month, picked.day, current.hour, current.minute);
      if (end) {
        _end = merged;
      } else {
        _start = merged;
        if (_end != null && _end!.isBefore(_start)) _end = _start;
      }
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (picked == null) return;
    setState(() => _start = DateTime(
        _start.year, _start.month, _start.day, picked.hour, picked.minute));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.event == null ? 'Nowe wydarzenie' : 'Wydarzenie',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                maxLength: 80,
                textCapitalization: TextCapitalization.sentences,
                decoration:
                    const InputDecoration(labelText: 'Tytuł', counterText: ''),
                onChanged: (_) => setState(() {}),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Cały dzień'),
                value: _allDay,
                onChanged: (v) => setState(() => _allDay = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: const Text('Początek'),
                subtitle: Text(dayLabel(_start)),
                onTap: () => _pickDay(false),
              ),
              if (!_allDay)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: const Text('Godzina'),
                  subtitle: Text(timeLabel(_start)),
                  onTap: _pickTime,
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_busy_outlined),
                title: const Text('Koniec (opcjonalnie)'),
                subtitle: Text(_end == null ? 'Brak' : dayLabel(_end!)),
                trailing: _end == null
                    ? null
                    : IconButton(
                        tooltip: 'Wyczyść koniec',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _end = null),
                      ),
                onTap: () => _pickDay(true),
              ),
              TextField(
                controller: _note,
                maxLength: 300,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: 'Notatka (opcjonalnie)', counterText: ''),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Widoczne dla wszystkich domowników'),
                value: _shared,
                onChanged: (v) => setState(() => _shared = v),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _valid
                    ? () => Navigator.pop(
                          context,
                          _EventResult.save(
                            title: _title.text.trim(),
                            start: _start,
                            end: _end,
                            allDay: _allDay,
                            note: _note.text.trim().isEmpty
                                ? null
                                : _note.text.trim(),
                            shared: _shared,
                          ),
                        )
                    : null,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder()),
                child: Text(widget.event == null ? 'Dodaj' : 'Zapisz'),
              ),
              if (widget.event != null)
                TextButton(
                  onPressed: () async {
                    final ok = await confirmDialog(context,
                        'Usunąć wydarzenie?', widget.event!.title, 'Usuń');
                    if (ok && context.mounted)
                      Navigator.pop(context, const _EventResult.remove());
                  },
                  style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error),
                  child: const Text('Usuń'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
