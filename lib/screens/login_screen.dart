import 'package:flutter/material.dart';

import '../mobilus/gateway_discovery.dart';
import '../state/credentials_store.dart';
import '../state/session_controller.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});

  final SessionController controller;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _remember = true;
  bool _obscure = true;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    widget.controller.lastHostAndLogin().then((v) {
      if (!mounted) return;
      final (host, login) = v;
      if (_host.text.isEmpty && host != null) _host.text = host;
      if (_login.text.isEmpty && login != null) _login.text = login;
      if (_host.text.isEmpty) _autoDiscover();
    });
  }

  /// Bez zapamiętanego adresu wpisuje pierwszą bramkę znalezioną w sieci.
  Future<void> _autoDiscover() async {
    try {
      final host = await GatewayDiscovery().scan().first;
      if (mounted && _host.text.isEmpty) _host.text = host;
    } catch (_) {
      // Nic nie znaleziono – użytkownik wpisze adres lub użyje wyszukiwania.
    }
  }

  Future<void> _searchGateway() async {
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    String? host;
    try {
      host = await GatewayDiscovery().scan().first;
    } catch (_) {
      // Pusty strumień – nie znaleziono bramki.
    }
    if (!mounted) return;
    setState(() => _searching = false);
    if (host != null) {
      _host.text = host;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Nie znaleziono bramki. Sprawdź, czy telefon jest w tej samej sieci Wi‑Fi.'),
      ));
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await widget.controller.login(
      GatewayCredentials(
        host: _host.text.trim(),
        login: _login.text.trim(),
        password: _password.text,
      ),
      remember: _remember,
    );
  }

  static String? _validateHost(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Podaj adres IP bramki';
    if (value.contains('://') || value.contains('/'))
      return 'Podaj sam adres, np. 192.168.1.20';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = widget.controller.phase == SessionPhase.connecting;
    final error = widget.controller.error;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.roofing_rounded,
                          size: 64, color: theme.colorScheme.primary),
                      const SizedBox(height: 12),
                      Text('NestIQ',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displaySmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text('Połącz się z bramką Mobilus Cosmo GTW',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 32),
                      TextFormField(
                        controller: _host,
                        enabled: !busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Adres bramki',
                          hintText: '192.168.1.20',
                          prefixIcon: const Icon(Icons.router_outlined),
                          suffixIcon: _searching
                              ? const Padding(
                                  padding: EdgeInsets.all(14),
                                  child: SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2.5)),
                                )
                              : IconButton(
                                  tooltip: 'Szukaj bramki w sieci',
                                  icon: const Icon(Icons.wifi_find_outlined),
                                  onPressed: busy ? null : _searchGateway,
                                ),
                        ),
                        validator: _validateHost,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _login,
                        enabled: !busy,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Użytkownik',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Podaj nazwę użytkownika'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !busy,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Hasło',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Pokaż hasło' : 'Ukryj hasło',
                            icon: Icon(_obscure
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Podaj hasło' : null,
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: _remember,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => _remember = v ?? true),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('Zapamiętaj mnie na tym urządzeniu'),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline,
                                  color: theme.colorScheme.onErrorContainer),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(error,
                                    style: TextStyle(
                                        color: theme
                                            .colorScheme.onErrorContainer)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: busy
                            ? const SizedBox.square(
                                dimension: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.5))
                            : const Text('Zaloguj'),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Telefon musi być w tej samej sieci co bramka. '
                        'Użytkownika i urządzenia dodasz w panelu bramki lub aplikacji Mobilus.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
