import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import '../shelly/shelly_controller.dart';
import '../shelly/shelly_models.dart';
import '../widgets/motion.dart';

/// Urządzenia Shelly: lista, dodawanie po adresie IP, zmiana nazwy i usuwanie.
class ShellyScreen extends StatelessWidget {
  const ShellyScreen({super.key, required this.shelly});

  final ShellyController shelly;

  Future<void> _add(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _AddSheet(shelly: shelly),
      );

  Future<void> _rename(BuildContext context, ShellyDevice device) async {
    final controller = TextEditingController(text: device.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nazwa urządzenia'),
        content:
            TextField(controller: controller, maxLength: 40, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Zapisz')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty)
      await shelly.rename(device.id, name);
  }

  Future<void> _remove(BuildContext context, ShellyDevice device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Usunąć urządzenie?'),
        content: Text(
            '${device.name} zniknie z aplikacji. Samo urządzenie działa dalej.'),
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
    if (ok == true) await shelly.remove(device.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Shelly')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: const Text('Dodaj urządzenie'),
      ),
      body: ListenableBuilder(
        listenable: shelly,
        builder: (context, _) {
          if (shelly.devices.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          shape: BoxShape.circle),
                      child: Icon(Icons.developer_board,
                          size: 30,
                          color: theme.colorScheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: 16),
                    Text('Nie dodano urządzeń Shelly',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      'Podaj adres IP urządzenia z tej samej sieci Wi‑Fi. Znajdziesz go w aplikacji Shelly lub w routerze. '
                      'Warto nadać urządzeniu stały adres w routerze.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              for (var i = 0; i < shelly.devices.length; i++)
                FadeUp(
                  index: i,
                  child: Card(
                    child: ListTile(
                      leading: Icon(shelly.isReachable(shelly.devices[i].id)
                          ? Icons.wifi
                          : Icons.wifi_off),
                      title: Text(shelly.devices[i].name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${shelly.devices[i].model} · ${shelly.devices[i].host}\n${_channels(shelly.devices[i])}'
                        '${shelly.isReachable(shelly.devices[i].id) ? '' : ' · niedostępne'}',
                      ),
                      isThreeLine: true,
                      onTap: () => _rename(context, shelly.devices[i]),
                      trailing: IconButton(
                        tooltip: 'Usuń ${shelly.devices[i].name}',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _remove(context, shelly.devices[i]),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _channels(ShellyDevice d) {
    final counts = <ShellyKind, int>{};
    for (final c in d.components) {
      counts[c.kind] = (counts[c.kind] ?? 0) + 1;
    }
    if (counts.isEmpty) return 'Brak rozpoznanych kanałów';
    return [for (final e in counts.entries) '${e.key.label}: ${e.value}']
        .join(', ');
  }
}

class _AddSheet extends StatefulWidget {
  const _AddSheet({required this.shelly});

  final ShellyController shelly;

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _host = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;
  ShellyDevice? _found;

  @override
  void dispose() {
    _host.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device = await widget.shelly.client.probe(_host.text);
      if (!mounted) return;
      _name.text = device.name;
      setState(() => _found = device);
    } on DeviceControlException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final device = _found!;
    final name = _name.text.trim().isEmpty ? device.name : _name.text.trim();
    await widget.shelly.add(device.copyWith(name: name));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final found = _found;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  found == null
                      ? 'Dodaj urządzenie Shelly'
                      : 'Znaleziono urządzenie',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              if (found == null) ...[
                TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'Adres IP', hintText: '192.168.1.50'),
                  onSubmitted: (_) => _busy ? null : _probe(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _probe,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: const StadiumBorder()),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Szukaj'),
                ),
              ] else ...[
                Text('${found.model} · Gen${found.gen} · ${found.host}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(ShellyScreen._channels(found),
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                TextField(
                    controller: _name,
                    maxLength: 40,
                    decoration: const InputDecoration(labelText: 'Nazwa')),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: found.components.isEmpty ? null : _save,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: const StadiumBorder()),
                  child: const Text('Dodaj'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
