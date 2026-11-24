import 'package:flutter/material.dart';

import '../mobilus/device_info.dart';
import '../mobilus/proto.dart';

/// Dni tygodnia w kolejności polskiego kalendarza; numeracja jak w bramce
/// (0 = niedziela, 1 = poniedziałek … 6 = sobota).
const _days = [
  (1, 'Pn'),
  (2, 'Wt'),
  (3, 'Śr'),
  (4, 'Cz'),
  (5, 'Pt'),
  (6, 'So'),
  (0, 'Nd')
];

/// Tworzenie i edycja sceny zapisanej w bramce – te same pola co w aplikacji Mobilus.
class GatewaySceneEditorScreen extends StatefulWidget {
  const GatewaySceneEditorScreen({
    super.key,
    required this.devices,
    required this.onSave,
    this.onRemove,
    this.scene,
  });

  final List<Device> devices;
  final GatewayScene? scene;

  /// Zapis w bramce; wyjątek zostaje na ekranie jako komunikat.
  final Future<void> Function(GatewayScene scene) onSave;
  final Future<void> Function(GatewayScene scene)? onRemove;

  @override
  State<GatewaySceneEditorScreen> createState() =>
      _GatewaySceneEditorScreenState();
}

class _GatewaySceneEditorScreenState extends State<GatewaySceneEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.scene?.name ?? '');
  late bool _active = widget.scene?.active ?? true;
  late bool _scheduled = widget.scene?.schedule.isNotEmpty ?? false;
  late TimeOfDay _time;
  late Set<int> _selectedDays;
  late final Map<int, String> _values = {
    for (final e in widget.scene?.events ?? const <DeviceEvent>[])
      e.deviceId: e.value,
  };
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final schedule = widget.scene?.schedule ?? const <SceneSchedule>[];
    if (schedule.isEmpty) {
      _time = const TimeOfDay(hour: 7, minute: 0);
      _selectedDays = {for (final (d, _) in _days) d};
    } else {
      _time = TimeOfDay.fromDateTime(schedule.first.localTime);
      _selectedDays = {for (final s in schedule) s.localDay};
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  static int? _percent(String? value) => value != null && value.endsWith('%')
      ? int.tryParse(value.replaceAll('%', ''))
      : null;

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_values.isEmpty)
      return _message('Wybierz co najmniej jedno urządzenie.');
    if (_scheduled && _selectedDays.isEmpty)
      return _message('Wybierz dni harmonogramu.');

    final isNew = widget.scene == null;
    final scene = GatewayScene(
      id: widget.scene?.id ?? 0,
      name: _name.text.trim(),
      active: _active,
      kind: widget.scene?.kind ?? 1,
      events: [
        // Aplikacja Mobilus przy nowej scenie wysyła też id zdarzenia = 0.
        for (final d in widget.devices)
          if (_values[d.id] case final value?)
            DeviceEvent(
              id: isNew ? 0 : null,
              deviceId: d.id,
              eventNumber: DeviceEvent.commandEventNumber,
              value: value,
            ),
      ],
      schedule: _scheduled
          ? SceneSchedule.fromLocal(_selectedDays, _time.hour, _time.minute)
          : const [],
    );

    setState(() => _saving = true);
    try {
      await widget.onSave(scene);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _message('Nie udało się zapisać: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove() async {
    final scene = widget.scene!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Usunąć „${scene.name}”?'),
        content: const Text(
            'Scena zniknie z bramki i z aplikacji Mobilus na wszystkich '
            'telefonach.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Usuń')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.onRemove!(scene);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _message('Nie udało się usunąć: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allDays = _selectedDays.length == 7;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.scene == null ? 'Nowa scena' : 'Edytuj scenę'),
        actions: [
          if (widget.scene != null && widget.onRemove != null && !_saving)
            IconButton(
              tooltip: 'Usuń scenę',
              icon: const Icon(Icons.delete_outline),
              onPressed: _remove,
            ),
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : TextButton(onPressed: _save, child: const Text('Zapisz')),
          const SizedBox(width: 8),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Nazwa sceny',
                  hintText: 'np. Dobranoc',
                  prefixIcon: Icon(Icons.auto_awesome_outlined),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Podaj nazwę sceny'
                    : null,
              ),
              const SizedBox(height: 16),
              Card(
                child: SwitchListTile(
                  secondary: Icon(_active
                      ? Icons.check_circle
                      : Icons.pause_circle_outline),
                  title: const Text('Aktywna'),
                  subtitle: Text(_active
                      ? 'Scena uruchamia się według harmonogramu'
                      : 'Harmonogram wstrzymany, scenę można uruchomić ręcznie'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ),
              const SizedBox(height: 24),
              Text('Harmonogram', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.schedule),
                      title: const Text('Uruchamiaj automatycznie'),
                      value: _scheduled,
                      onChanged: (v) => setState(() => _scheduled = v),
                    ),
                    if (_scheduled) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.access_time),
                        title: const Text('Godzina'),
                        trailing: Text(_time.format(context),
                            style: theme.textTheme.titleMedium),
                        onTap: _pickTime,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final (day, label) in _days)
                                  FilterChip(
                                    label: Text(label),
                                    showCheckmark: false,
                                    selected: _selectedDays.contains(day),
                                    onSelected: (on) => setState(() => on
                                        ? _selectedDays.add(day)
                                        : _selectedDays.remove(day)),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => setState(() => _selectedDays =
                                  allDays
                                      ? <int>{}
                                      : {for (final (d, _) in _days) d}),
                              icon: Icon(
                                  allDays ? Icons.clear_all : Icons.done_all),
                              label:
                                  Text(allDays ? 'Wyczyść dni' : 'Codziennie'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('Urządzenia', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final d in widget.devices) _deviceCard(theme, d),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceCard(ThemeData theme, Device d) {
    final type = MobilusDeviceType.fromCode(d.type);
    final value = _values[d.id];
    final percent = _percent(value);

    final options = <(String, String)>[
      if (type.isSwitch) ...[
        ('ON', 'Włącz'),
        ('OFF', 'Wyłącz')
      ] else ...[
        ('UP', 'Otwórz'),
        ('DOWN', 'Zamknij'),
      ],
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.name.isEmpty ? 'Urządzenie ${d.id}' : d.name,
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Pomiń'),
                    selected: value == null,
                    onSelected: (_) => setState(() => _values.remove(d.id)),
                  ),
                  for (final (v, label) in options)
                    ChoiceChip(
                      label: Text(label),
                      selected: value == v,
                      onSelected: (_) => setState(() => _values[d.id] = v),
                    ),
                  if (type.supportsPosition)
                    ChoiceChip(
                      label: Text(
                          percent == null ? 'Pozycja' : 'Otwarta w $percent%'),
                      selected: percent != null,
                      onSelected: (_) =>
                          setState(() => _values[d.id] = '${percent ?? 50}%'),
                    ),
                ],
              ),
              // Suwak jak na ekranie Dom: w prawo = bardziej zamknięta.
              if (percent != null)
                Row(
                  children: [
                    const Icon(Icons.vertical_align_top, size: 18),
                    Expanded(
                      child: Slider(
                        value: (100 - percent).clamp(0, 100).toDouble(),
                        max: 100,
                        divisions: 100,
                        label: 'Otwarta w $percent%',
                        onChanged: (v) => setState(
                            () => _values[d.id] = '${(100 - v).round()}%'),
                      ),
                    ),
                    const Icon(Icons.vertical_align_bottom, size: 18),
                  ],
                )
              else
                const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
