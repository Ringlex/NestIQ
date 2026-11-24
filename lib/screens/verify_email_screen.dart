import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/account_controller.dart';
import '../account/account_models.dart';
import '../widgets/forms.dart';
import '../widgets/motion.dart';

/// Wpisanie sześciocyfrowego kodu z maila po rejestracji.
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, required this.account});

  final AccountController account;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _info;
  int _cooldown = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown = (_cooldown - 1).clamp(0, 60));
      if (_cooldown == 0) t.cancel();
    });
  }

  Future<void> _verify() async {
    if (_code.text.length != 6) {
      setState(() => _error = 'Kod ma 6 cyfr.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await widget.account.verify(_code.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _error = null;
      _info = null;
    });
    try {
      await widget.account.resendCode();
      if (!mounted) return;
      setState(() => _info = 'Wysłaliśmy nowy kod.');
      _startCooldown();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final email = widget.account.pendingEmail ?? '';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Wróć',
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.account.cancelVerification,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FadeUp(
                    child: Icon(Icons.mark_email_unread_outlined,
                        size: 56, color: scheme.primary),
                  ),
                  const SizedBox(height: 16),
                  FadeUp(
                    index: 1,
                    child: Text('Sprawdź skrzynkę',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: 8),
                  FadeUp(
                    index: 2,
                    child: Text('Wysłaliśmy 6-cyfrowy kod na adres\n$email',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(letterSpacing: 10),
                    autofillHints: const [AutofillHints.oneTimeCode],
                    onChanged: (v) {
                      if (v.length == 6) _verify();
                    },
                    decoration: const InputDecoration(
                        counterText: '', hintText: '••••••'),
                  ),
                  ErrorBanner(_error),
                  if (_info != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_info!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.primary)),
                    ),
                  const SizedBox(height: 20),
                  LoadingButton(
                    label: 'Potwierdź',
                    busyLabel: 'Sprawdzanie…',
                    busy: _busy,
                    onPressed: _verify,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _cooldown == 0 && !_busy ? _resend : null,
                    child: Text(_cooldown == 0
                        ? 'Wyślij kod ponownie'
                        : 'Wyślij ponownie za $_cooldown s'),
                  ),
                  Text(
                      'Kod wygasa po 10 minutach. Zajrzyj też do folderu ze spamem.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
