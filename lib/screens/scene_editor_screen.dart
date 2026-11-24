import 'package:flutter/material.dart';

import '../mobilus/device_info.dart';
import '../mobilus/proto.dart';
import '../state/scenes_controller.dart';

/// Tworzenie i edycja sceny: nazwa oraz komenda dla wybranych urządzeń.
class SceneEditorScreen extends StatefulWidget {
  const SceneEditorScreen({super.key, required this.devices, this.scene});

  final List<Device> devices;
  final Scene? scene;

  @override
  State<SceneEditorScreen> createState() => _SceneEditorScreenState();
}

class _SceneEditorScreenState extends State<SceneEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.scene?.name ?? '');
  late final Map<int, String> _values = {
    for (final a in widget.scene?.actions ?? const <SceneAction>[])
      a.deviceId: a.value,
  };

  static List<(String, String)> _options(MobilusDeviceType type) {
    if (type.isSwitch) return const [('ON', 'Włącz'), ('OFF', 'Wyłącz')];
    if (type.isGarage) return const [('UP', 'Otwórz'), ('DOWN', 'Zamknij')];
    return [
      ('UP', 'Otwórz'),
      ('DOWN', 'Zamknij'),
      if (type.supportsPosition) ...[
        ('25%', '25%'),
        ('50%', '50%'),
        ('75%', '75%')
      ],
    ];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_values.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Wybierz co najmniej jedno urządzenie.')));
      return;
    }
    Navigator.pop(
      context,
      Scene(
        id: widget.scene?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: _name.text.trim(),
        actions: [
          for (final MapEntry(key: id, value: value) in _values.entries)
            SceneAction(deviceId: id, value: value),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.scene == null ? 'Nowa scena' : 'Edytuj scenę'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Zapisz')),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nazwa sceny',
                hintText: 'np. Dobranoc',
                prefixIcon: Icon(Icons.auto_awesome_outlined),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Podaj nazwę sceny' : null,
            ),
            const SizedBox(height: 24),
            Text('Urządzenia', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final d in widget.devices)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('Pomiń'),
                              selected: !_values.containsKey(d.id),
                              onSelected: (_) =>
                                  setState(() => _values.remove(d.id)),
                            ),
                            for (final (value, label)
                                in _options(MobilusDeviceType.fromCode(d.type)))
                              ChoiceChip(
                                label: Text(label),
                                selected: _values[d.id] == value,
                                onSelected: (_) =>
                                    setState(() => _values[d.id] = value),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
