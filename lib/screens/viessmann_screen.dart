import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../viessmann/fault_service.dart';
import '../viessmann/viessmann_controller.dart';
import '../viessmann/viessmann_models.dart';
import '../widgets/forms.dart';
import '../widgets/heating_cards.dart';

/// Połączenie z piecem Viessmann przez konto ViCare (Ustawienia → Piec Viessmann).
class ViessmannScreen extends StatefulWidget {
  const ViessmannScreen(
      {super.key, required this.viessmann, required this.faults});

  final ViessmannController viessmann;
  final FaultService faults;

  @override
  State<ViessmannScreen> createState() => _ViessmannScreenState();
}

class _ViessmannScreenState extends State<ViessmannScreen> {
  late final _clientId =
      TextEditingController(text: widget.viessmann.clientId ?? '');
  String? _error;

  @override
  void dispose() {
    _clientId.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    try {
      await widget.viessmann.connect(_clientId.text);
      if (mounted) Navigator.of(context).maybePop();
    } on ViessmannException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rozłączyć piec?'),
        content: const Text(
            'Zapisane logowanie do ViCare zostanie usunięte z tego telefonu.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Rozłącz')),
        ],
      ),
    );
    if (ok == true) await widget.viessmann.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = widget.viessmann;

    return Scaffold(
      appBar: AppBar(title: const Text('Piec Viessmann')),
      body: ListenableBuilder(
        listenable: v,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (v.isConfigured && !v.sessionExpired)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.check_circle, color: scheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text('Połączono z kontem ViCare',
                                  style: theme.textTheme.titleSmall)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Urządzenie: ${v.device!.modelId}\n'
                        '${v.state == null ? 'Brak odczytu.' : 'Ostatni odczyt: ${formatTime(v.state!.fetchedAt)}'}\n'
                        'Zapytania z ostatniej doby: ${v.callsLast24h} z ${ViessmannController.dailyLimit}',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      ErrorBanner(v.error),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonal(
                              onPressed:
                                  v.busy ? null : () => v.refresh(force: true),
                              child: const Text('Odśwież teraz'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: v.busy ? null : _disconnect,
                            style: TextButton.styleFrom(
                                foregroundColor: scheme.error),
                            child: const Text('Rozłącz'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (v.sessionExpired)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text('Sesja wygasła. Zaloguj się ponownie.',
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: scheme.error)),
                        ),
                      TextField(
                        controller: _clientId,
                        enabled: !v.busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Client ID',
                          prefixIcon: Icon(Icons.key_outlined),
                          helperText:
                              'Z portalu deweloperskiego Viessmanna (My Dashboard).',
                        ),
                      ),
                      ErrorBanner(_error),
                      const SizedBox(height: 16),
                      LoadingButton(
                        label: 'Zaloguj do ViCare',
                        busyLabel: 'Łączenie…',
                        busy: v.busy,
                        onPressed: _connect,
                      ),
                    ],
                  ),
                ),
              ),
            if (v.isConfigured && !v.sessionExpired) ...[
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: widget.faults,
                builder: (context, _) => Card(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: const Text('Powiadomienia o usterkach'),
                    subtitle: Text(
                      defaultTargetPlatform == TargetPlatform.iOS
                          ? 'Telefon pokaże powiadomienie o nowej usterce lub komunikacie serwisowym. '
                              'Gdy aplikacja jest zamknięta, iPhone sprawdza piec rzadko i w terminach wybranych przez system.'
                          : 'Telefon pokaże powiadomienie o nowej usterce lub komunikacie serwisowym, '
                              'także gdy aplikacja jest zamknięta (sprawdzanie co ok. 30 minut).',
                    ),
                    value: widget.faults.enabled,
                    onChanged: (value) async {
                      final messenger = ScaffoldMessenger.of(context);
                      final result = await widget.faults.setEnabled(value);
                      if (result == FaultEnableResult.permissionDenied) {
                        messenger
                          ..hideCurrentSnackBar()
                          ..showSnackBar(const SnackBar(
                            content: Text(
                                'Brak zgody na powiadomienia. Włącz je dla NestIQ w ustawieniach telefonu.'),
                          ));
                      }
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: !v.isConfigured,
                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                title: const Text('Jak to skonfigurować?'),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Text(
                      '1. Wejdź na developer.viessmann-climatesolutions.com → My Dashboard i zaloguj się kontem ViCare.\n'
                      '2. Utwórz klienta (plan Basic jest darmowy), wyłącz reCAPTCHA i dodaj adres przekierowania:\n'
                      '    $viessmannRedirectUri\n'
                      '3. Skopiuj Client ID i wpisz go powyżej. Logowanie odbywa się na stronie Viessmanna, '
                      'NestIQ nie widzi hasła do ViCare.\n\n'
                      'Viessmann pozwala na 1450 zapytań na dobę dla całego konta. Odczyt odbywa się tylko przy otwartej '
                      'zakładce Ogrzewanie, co kilka minut, więc limit wystarcza z zapasem. Piec nie ma połączenia '
                      'lokalnego: bez internetu zakładka nie działa.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
