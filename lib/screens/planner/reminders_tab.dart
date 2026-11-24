import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../household/household_controller.dart';
import '../../household/household_models.dart';
import '../../household/recurrence.dart';
import '../../widgets/responsive.dart';
import 'planner_common.dart';

IconData reminderIcon(ReminderKind kind) => switch (kind) {
      ReminderKind.waterFilter => Icons.water_drop_outlined,
      ReminderKind.coffeeClean => Icons.coffee_outlined,
      ReminderKind.insurance => Icons.shield_outlined,
      ReminderKind.birthday => Icons.cake_outlined,
      ReminderKind.custom => Icons.notifications_none,
    };

String repeatSummary(Reminder r) {
  if (!r.repeats) return 'Jednorazowo';
  final every = switch (r.repeatUnit) {
    RepeatUnit.day =>
      r.repeatEvery == 1 ? 'codziennie' : 'co ${r.repeatEvery} dni',
    RepeatUnit.month =>
      r.repeatEvery == 1 ? 'co miesiąc' : 'co ${r.repeatEvery} mies.',
    RepeatUnit.year =>
      r.repeatEvery == 1 ? 'co rok' : 'co ${r.repeatEvery} lat',
  };
  return r.anchorAfterDone ? '$every od wykonania' : every;
}

/// Gotowe wzorce przypomnień z sensownymi domyślnymi ustawieniami.
class ReminderPreset {
  const ReminderPreset({
    required this.kind,
    required this.label,
    required this.title,
    required this.every,
    required this.unit,
    required this.afterDone,
    required this.lead,
    required this.defaultMonthsAhead,
    required this.hint,
  });

  final ReminderKind kind;
  final String label;
  final String title;
  final int every;
  final RepeatUnit unit;
  final bool afterDone;
  final int lead;
  final int defaultMonthsAhead;
  final String hint;

  Reminder toReminder(DateTime today, String ownerId) => Reminder(
        id: '',
        ownerProfileId: ownerId,
        kind: kind,
        title: title,
        date: addInterval(today, defaultMonthsAhead, RepeatUnit.month),
        repeatEvery: every,
        repeatUnit: unit,
        anchorAfterDone: afterDone,
        leadDays: lead,
      );

  static const all = [
    ReminderPreset(
      kind: ReminderKind.waterFilter,
      label: 'Wymiana filtra do wody',
      title: 'Wymiana filtra do wody',
      every: 3,
      unit: RepeatUnit.month,
      afterDone: true,
      lead: 3,
      defaultMonthsAhead: 3,
      hint:
          'Co 3 miesiące od wymiany. Interwał ustaw według instrukcji filtra.',
    ),
    ReminderPreset(
      kind: ReminderKind.coffeeClean,
      label: 'Czyszczenie ekspresu do kawy',
      title: 'Czyszczenie ekspresu do kawy',
      every: 1,
      unit: RepeatUnit.month,
      afterDone: true,
      lead: 0,
      defaultMonthsAhead: 1,
      hint:
          'Co miesiąc od ostatniego czyszczenia. Odkamienianie możesz dodać jako osobne przypomnienie.',
    ),
    ReminderPreset(
      kind: ReminderKind.insurance,
      label: 'Ubezpieczenie mieszkania lub domu',
      title: 'Ubezpieczenie mieszkania/domu',
      every: 1,
      unit: RepeatUnit.year,
      afterDone: false,
      lead: 30,
      defaultMonthsAhead: 12,
      hint: 'Co roku w dniu końca polisy, z przypomnieniem 30 dni wcześniej.',
    ),
    ReminderPreset(
      kind: ReminderKind.birthday,
      label: 'Urodziny',
      title: 'Urodziny ',
      every: 1,
      unit: RepeatUnit.year,
      afterDone: false,
      lead: 7,
      defaultMonthsAhead: 0,
      hint: 'Co roku, z przypomnieniem tydzień wcześniej i w samym dniu.',
    ),
    ReminderPreset(
      kind: ReminderKind.custom,
      label: 'Własne przypomnienie',
      title: '',
      every: 0,
      unit: RepeatUnit.month,
      afterDone: false,
      lead: 0,
      defaultMonthsAhead: 0,
      hint: 'Dowolny termin, jednorazowy albo cykliczny.',
    ),
  ];
}

/// Zakładka „Przypomnienia”: filtr do wody, ekspres, ubezpieczenie, urodziny.
class RemindersTab extends StatelessWidget {
  const RemindersTab(
      {super.key,
      required this.household,
      required this.account,
      DateTime Function()? clock})
      : _clock = clock;

  final HouseholdController household;
  final AccountController account;
  final DateTime Function()? _clock;

  DateTime get _today => dateOnly(_clock?.call() ?? DateTime.now());

  Future<void> _add(BuildContext context) async {
    final preset = await showModalBottomSheet<ReminderPreset>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Co przypominać?',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final p in ReminderPreset.all)
              ListTile(
                leading: Icon(reminderIcon(p.kind)),
                title: Text(p.label),
                subtitle: Text(p.hint),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    );
    if (preset == null || !context.mounted) return;
    await _edit(context, preset.toReminder(_today, account.active?.id ?? ''),
        isNew: true);
  }

  Future<void> _edit(BuildContext context, Reminder reminder,
      {bool isNew = false}) async {
    final result = await showModalBottomSheet<_EditorResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          ReminderEditor(reminder: reminder, isNew: isNew, today: _today),
    );
    if (result == null || !context.mounted) return;
    if (result.delete) {
      await guarded(context, () => household.deleteReminder(reminder.id));
    } else if (isNew) {
      await guarded(context, () => household.createReminder(result.reminder!));
    } else {
      await guarded(context,
          () => household.updateReminder(reminder.id, result.reminder!));
    }
  }

  Future<void> _done(BuildContext context, Reminder r) async {
    final ok = await guarded(
        context, () => household.completeReminder(r.id, now: _clock?.call()));
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Zapisano: ${r.title}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = _today;
    final all = [
      for (final r in household.reminders)
        if (!r.completed) r
    ]..sort((a, b) => a.effectiveDate(today).compareTo(b.effectiveDate(today)));
    final overdue = [
      for (final r in all)
        if (r.isOverdue(today)) r
    ];
    final soon = [
      for (final r in all)
        if (!r.isOverdue(today) &&
            r.effectiveDate(today).difference(today).inDays <= 30)
          r,
    ];
    final later = [
      for (final r in all)
        if (!overdue.contains(r) && !soon.contains(r)) r
    ];

    Widget section(String title, List<Reminder> items, {bool danger = false}) {
      if (items.isEmpty) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: danger ? theme.colorScheme.error : null)),
          ),
          for (final r in items)
            _ReminderTile(
              reminder: r,
              today: today,
              names: ProfileNames.of(account),
              onTap: () => _edit(context, r),
              onDone: r.kind == ReminderKind.birthday
                  ? null
                  : () => _done(context, r),
            ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _add(context),
        icon: const Icon(Icons.add_alert_outlined),
        label: const Text('Przypomnienie'),
      ),
      body: RefreshIndicator(
        onRefresh: household.refreshReminders,
        child: all.isEmpty
            ? ListView(children: const [
                SizedBox(height: 80),
                PlannerEmpty(
                  icon: Icons.event_repeat,
                  title: 'Brak przypomnień',
                  message:
                      'Dodaj wymianę filtra do wody, czyszczenie ekspresu, termin ubezpieczenia albo urodziny. '
                      'Telefon przypomni we właściwym dniu.',
                ),
              ])
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                children: [
                  // Na szerokim ekranie sekcje stoją obok siebie.
                  ResponsiveColumns(minColumnWidth: 380, children: [
                    section('Zaległe', overdue, danger: true),
                    section('W ciągu 30 dni', soon),
                    section('Później', later),
                  ]),
                ],
              ),
      ),
    );
  }
}

class _ReminderTile extends StatelessWidget {
  const _ReminderTile({
    required this.reminder,
    required this.today,
    required this.names,
    required this.onTap,
    required this.onDone,
  });

  final Reminder reminder;
  final DateTime today;
  final ProfileNames names;
  final VoidCallback onTap;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final due = reminder.effectiveDate(today);
    final overdue = reminder.isOverdue(today);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: overdue
                        ? scheme.errorContainer
                        : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(reminderIcon(reminder.kind),
                      size: 22,
                      color: overdue
                          ? scheme.onErrorContainer
                          : scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(reminder.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      Text('${dayLabel(due)} · ${relativeDay(due, today)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: overdue
                                  ? scheme.error
                                  : scheme.onSurfaceVariant)),
                      Text(
                        [
                          repeatSummary(reminder),
                          if (reminder.leadDays > 0)
                            'przypomnienie ${reminder.leadDays} dni wcześniej',
                          if (!reminder.shared) 'prywatne',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (onDone != null)
                  IconButton.filledTonal(
                      tooltip: 'Zrobione',
                      onPressed: onDone,
                      icon: const Icon(Icons.check)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorResult {
  const _EditorResult.save(Reminder this.reminder) : delete = false;
  const _EditorResult.remove()
      : reminder = null,
        delete = true;

  final Reminder? reminder;
  final bool delete;
}

/// Formularz przypomnienia (nowego albo istniejącego).
class ReminderEditor extends StatefulWidget {
  const ReminderEditor(
      {super.key,
      required this.reminder,
      required this.isNew,
      required this.today});

  final Reminder reminder;
  final bool isNew;
  final DateTime today;

  @override
  State<ReminderEditor> createState() => _ReminderEditorState();
}

class _ReminderEditorState extends State<ReminderEditor> {
  late final _title = TextEditingController(text: widget.reminder.title);
  late final _note = TextEditingController(text: widget.reminder.note ?? '');
  late DateTime _date = widget.reminder.date;
  late int _every = widget.reminder.repeatEvery;
  late RepeatUnit _unit = widget.reminder.repeatUnit;
  late bool _afterDone = widget.reminder.anchorAfterDone;
  late int _lead = widget.reminder.leadDays;
  late bool _shared = widget.reminder.shared;

  static const _leadOptions = [0, 1, 3, 7, 14, 30];

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(widget.today.year - 1),
      lastDate: DateTime(widget.today.year + 15),
      helpText: 'Termin',
    );
    if (picked != null) setState(() => _date = dateOnly(picked));
  }

  void _save() {
    Navigator.pop(
      context,
      _EditorResult.save(Reminder(
        id: widget.reminder.id,
        ownerProfileId: widget.reminder.ownerProfileId,
        kind: widget.reminder.kind,
        title: _title.text.trim(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        date: _date,
        repeatEvery: _every,
        repeatUnit: _unit,
        anchorAfterDone: _every > 0 && _afterDone,
        leadDays: _lead,
        shared: _shared,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final birthday = widget.reminder.kind == ReminderKind.birthday;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.isNew ? 'Nowe przypomnienie' : 'Przypomnienie',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                maxLength: 80,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: birthday ? 'Czyje urodziny?' : 'Co przypomnieć?',
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: Text(birthday ? 'Data urodzin' : 'Termin'),
                subtitle: Text(dayLabel(_date)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _pickDate,
              ),
              const Divider(),
              Text('Powtarzanie', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                      label: const Text('Jednorazowo'),
                      selected: _every == 0,
                      onSelected: (_) => setState(() => _every = 0)),
                  ChoiceChip(
                    label: const Text('Cyklicznie'),
                    selected: _every > 0,
                    onSelected: (_) =>
                        setState(() => _every = _every == 0 ? 1 : _every),
                  ),
                ],
              ),
              if (_every > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Co'),
                    IconButton(
                        tooltip: 'Mniej',
                        onPressed:
                            _every > 1 ? () => setState(() => _every--) : null,
                        icon: const Icon(Icons.remove_circle_outline)),
                    Text('$_every', style: theme.textTheme.titleMedium),
                    IconButton(
                        tooltip: 'Więcej',
                        onPressed: _every < 120
                            ? () => setState(() => _every++)
                            : null,
                        icon: const Icon(Icons.add_circle_outline)),
                  ],
                ),
                SegmentedButton<RepeatUnit>(
                  showSelectedIcon: false,
                  segments: [
                    for (final u in RepeatUnit.values)
                      ButtonSegment(
                          value: u,
                          label: Text(u.label, overflow: TextOverflow.ellipsis))
                  ],
                  selected: {_unit},
                  onSelectionChanged: (s) => setState(() => _unit = s.first),
                ),
                if (!birthday)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Licz od dnia wykonania'),
                    subtitle: Text(_afterDone
                        ? 'Po kliknięciu „Zrobione” kolejny termin liczy się od tego dnia (filtr, ekspres).'
                        : 'Kolejny termin zawsze w tym samym dniu (polisa, urodziny).'),
                    value: _afterDone,
                    onChanged: (v) => setState(() => _afterDone = v),
                  ),
              ],
              const Divider(),
              Text('Przypomnij wcześniej', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in _leadOptions)
                    ChoiceChip(
                      label: Text(d == 0
                          ? 'Tylko w dniu'
                          : d == 7
                              ? 'Tydzień'
                              : '$d dni'),
                      selected: _lead == d,
                      onSelected: (_) => setState(() => _lead = d),
                    ),
                ],
              ),
              const SizedBox(height: 8),
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
                subtitle: const Text(
                    'Wyłączone: tylko Ty zobaczysz to przypomnienie.'),
                value: _shared,
                onChanged: (v) => setState(() => _shared = v),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _valid ? _save : null,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder()),
                child: Text(widget.isNew ? 'Dodaj' : 'Zapisz'),
              ),
              if (!widget.isNew)
                TextButton(
                  onPressed: () async {
                    final ok = await confirmDialog(context,
                        'Usunąć przypomnienie?', widget.reminder.title, 'Usuń');
                    if (ok && context.mounted)
                      Navigator.pop(context, const _EditorResult.remove());
                  },
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: const Text('Usuń'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
