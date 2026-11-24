import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import '../somfy/somfy_controller.dart';

/// Somfy TaHoma: adres lub PIN skrzynki i token z trybu dewelopera.
class SomfyScreen extends StatefulWidget {
  const SomfyScreen({super.key, required this.somfy});

  final SomfyController somfy;

  @override
  State<SomfyScreen> createState() => _SomfyScreenState();
}

class _SomfyScreenState extends State<SomfyScreen> {
  final _host = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  bool _showToken = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    super.dispose();
  }

  bool get _ready =>
      _host.text.trim().isNotEmpty && _token.text.trim().isNotEmpty;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final gateway =
          await widget.somfy.client.connect(_host.text, _token.text);
      await widget.somfy.connect(gateway);
    } on DeviceControlException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Odłączyć skrzynkę Somfy?'),
        content: const Text(
            'Token zostanie usunięty z tego telefonu. Skrzynka i rolety działają dalej.'),
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
    if (ok == true) await widget.somfy.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Somfy TaHoma')),
      body: ListenableBuilder(
        listenable: widget.somfy,
        builder: (context, _) {
          final gateway = widget.somfy.gateway;
          if (gateway != null) {
            final covers = widget.somfy.covers;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(widget.somfy.reachable
                        ? Icons.router_outlined
                        : Icons.wifi_off),
                    title: Text('Skrzynka ${gateway.id}'),
                    subtitle: Text(widget.somfy.reachable
                        ? 'Połączono · urządzeń: ${covers.length}'
                        : 'Niedostępna'),
                  ),
                ),
                const SizedBox(height: 8),
                for (final c in covers)
                  ListTile(
                    leading: const Icon(Icons.blinds),
                    title: Text(c.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.status),
                  ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _disconnect,
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                      foregroundColor: scheme.error),
                  child: const Text('Odłącz skrzynkę'),
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('Połącz skrzynkę TaHoma',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Potrzebny jest tryb dewelopera (lokalne API Somfy):\n'
                '1. W aplikacji TaHoma otwórz „Skonfiguruj instalację” › „Dostęp do parametrów” i siedem razy dotknij numeru PIN skrzynki.\n'
                '2. W menu „Tryb dewelopera” utwórz token. Pokaże się tylko raz, więc od razu go tu wklej.\n'
                '3. Podaj numer PIN (np. 2001-1234-5678) albo adres IP skrzynki.\n'
                'Nazwy w aplikacji TaHoma mogą się różnić w zależności od wersji. Najstarsza kwadratowa skrzynka TaHoma i Connectivity Kit nie są obsługiwane.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'PIN lub adres IP skrzynki',
                    hintText: '2001-1234-5678'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                obscureText: !_showToken,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Token',
                  suffixIcon: IconButton(
                    tooltip: _showToken ? 'Ukryj token' : 'Pokaż token',
                    icon: Icon(
                        _showToken ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showToken = !_showToken),
                  ),
                ),
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
                onPressed: _busy || !_ready ? null : _connect,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder()),
                child: _busy
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
