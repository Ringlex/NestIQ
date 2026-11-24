import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/account_controller.dart';
import '../account/account_models.dart';
import '../widgets/forms.dart';

/// Reset hasła: najpierw kod na maila, potem kod i nowe hasło.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen(
      {super.key, required this.account, this.initialEmail = ''});

  final AccountController account;
  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    if (!emailPattern.hasMatch(_email.text.trim())) {
      setState(() => _error = 'Podaj poprawny adres e-mail, np. anna@wp.pl.');
      return;
    }
    await _run(() async {
      await widget.account.forgotPassword(_email.text.trim().toLowerCase());
      if (mounted) setState(() => _codeSent = true);
    });
  }

  Future<void> _reset() async {
    if (_code.text.length != 6) {
      setState(() => _error = 'Kod ma 6 cyfr.');
      return;
    }
    if (_password.text.length < 8) {
      setState(() => _error = 'Hasło musi mieć min. 8 znaków.');
      return;
    }
    await _run(() async {
      await widget.account.resetPassword(
          _email.text.trim().toLowerCase(), _code.text, _password.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Hasło zmienione. Zaloguj się nowym hasłem.')));
      Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Zmiana hasła')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _codeSent
                        ? 'Jeśli konto istnieje, wysłaliśmy kod na ${_email.text.trim()}. '
                            'Wpisz go i ustaw nowe hasło.'
                        : 'Podaj adres konta. Wyślemy na niego 6-cyfrowy kod.',
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _email,
                    enabled: !_busy && !_codeSent,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Adres e-mail',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                  ),
                  if (_codeSent) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _code,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Kod z wiadomości',
                        counterText: '',
                        prefixIcon: Icon(Icons.pin_outlined),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Nowe hasło',
                        helperText:
                            'Minimum 8 znaków. Zmiana wyloguje wszystkie urządzenia.',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                  ],
                  ErrorBanner(_error),
                  const SizedBox(height: 20),
                  LoadingButton(
                    label: _codeSent ? 'Ustaw nowe hasło' : 'Wyślij kod',
                    busyLabel: 'Chwileczkę…',
                    busy: _busy,
                    onPressed: _codeSent ? _reset : _sendCode,
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
