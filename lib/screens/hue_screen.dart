import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import '../hue/hue_controller.dart';
import '../hue/hue_models.dart';

/// Philips Hue: znajdź mostek, naciśnij na nim przycisk i połącz; potem podgląd lamp.
class HueScreen extends StatefulWidget {
  const HueScreen({super.key, required this.hue});

  final HueController hue;

  @override
  State<HueScreen> createState() => _HueScreenState();
}

class _HueScreenState extends State<HueScreen> {
  final _host = TextEditingController();
  List<HueBridgeInfo> _found = const [];
  bool _searching = false;
  bool _searched = false;
  bool _pairing = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    final found = await widget.hue.client.discover();
    if (!mounted) return;
    setState(() {
      _found = found;
      _searching = false;
      _searched = true;
      if (found.length == 1) _host.text = found.first.host;
    });
  }

  Future<void> _pair() async {
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final bridge = await widget.hue.client.pair(_host.text);
      await widget.hue.connect(bridge);
    } on DeviceControlException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Odłączyć mostek Hue?'),
        content: const Text(
            'Klucz zostanie usunięty z tego telefonu. Lampy i mostek działają dalej.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Odłącz')),
        ],
      ),
    );
    if (ok == true) await widget.hue.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Philips Hue')),
      body: ListenableBuilder(
        listenable: widget.hue,
        builder: (context, _) {
          final bridge = widget.hue.bridge;
          if (bridge != null) {
            final lights = widget.hue.lights;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(widget.hue.reachable
                        ? Icons.hub_outlined
                        : Icons.wifi_off),
                    title: Text('Mostek ${bridge.host}'),
                    subtitle: Text(widget.hue.reachable
                        ? 'Połączono · lamp: ${lights.length}'
                        : 'Niedostępny'),
                  ),
                ),
                const SizedBox(height: 8),
                for (final l in lights)
                  ListTile(
                    leading: const Icon(Icons.lightbulb_outline),
                    title: Text(l.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(l.status),
                  ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _disconnect,
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                      foregroundColor: scheme.error),
                  child: const Text('Odłącz mostek'),
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('Połącz mostek Hue', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Telefon musi być w tej samej sieci Wi‑Fi co mostek. Wpisz adres mostka (jest w aplikacji Hue lub w routerze) '
                'albo użyj wyszukiwania. Potem naciśnij okrągły przycisk na mostku i wybierz „Połącz”.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _searching ? null : _search,
                icon: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: const Text('Znajdź mostek'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: const StadiumBorder()),
              ),
              if (_searched && _found.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Nie znaleziono mostka. Wpisz adres ręcznie.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              if (_found.length > 1)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final b in _found)
                      ActionChip(
                          label: Text(b.host),
                          onPressed: () => setState(() => _host.text = b.host)),
                  ],
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'Adres mostka', hintText: '192.168.1.2'),
                onChanged: (_) => setState(() {}),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _pairing || _host.text.trim().isEmpty ? null : _pair,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder()),
                child: _pairing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Połącz'),
              ),
            ],
          );
        },
      ),
    );
  }
}
