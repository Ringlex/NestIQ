import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../account/account_models.dart';
import '../widgets/forms.dart';
import '../widgets/motion.dart';
import 'forgot_password_screen.dart';
import '../widgets/responsive.dart';

/// Logowanie i rejestracja kontem e-mail + hasło (dowolna skrzynka).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.account});

  final AccountController account;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _register = false;
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.account.lastEmail().then((value) {
      if (mounted && _email.text.isEmpty && value != null) _email.text = value;
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _setMode(int index) => setState(() {
        _register = index == 1;
        _error = null;
      });

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final email = _email.text.trim().toLowerCase();
    try {
      if (_register) {
        await widget.account.register(email, _password.text);
      } else {
        await widget.account.login(email, _password.text);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

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
                      FadeUp(
                        child: Row(
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(Icons.roofing_rounded,
                                  size: 30, color: scheme.onPrimaryContainer),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                                child: Text('NestIQ',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            color: scheme.primary))),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                      FadeUp(
                        index: 1,
                        child: AnimatedSwitcher(
                          duration: Motion.toggle,
                          child: Column(
                            key: ValueKey(_register),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  _register
                                      ? 'Załóż konto.'
                                      : 'Witaj z powrotem.',
                                  style: theme.textTheme.displaySmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      height: 1.1)),
                              const SizedBox(height: 8),
                              Text(
                                _register
                                    ? 'Podaj e-mail i hasło. Zaraz potem utworzysz swój profil administratora.'
                                    : 'Zaloguj się e-mailem i hasłem, żeby sterować światłami i roletami.',
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      FadeUp(
                        index: 2,
                        child: SlidingTabs(
                          labels: const ['Zaloguj się', 'Zarejestruj się'],
                          icons: const [Icons.login, Icons.person_add_alt_1],
                          index: _register ? 1 : 0,
                          onChanged: _busy ? (_) {} : _setMode,
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Adres e-mail',
                          prefixIcon: Icon(Icons.mail_outline),
                        ),
                        validator: (v) => emailPattern
                                .hasMatch((v ?? '').trim())
                            ? null
                            : 'Podaj poprawny adres e-mail, np. anna@wp.pl.',
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autofillHints: [
                          _register
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        textInputAction: _register
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onFieldSubmitted: (_) => _register ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: 'Hasło',
                          helperText: _register ? 'Minimum 8 znaków.' : null,
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
                        validator: (v) {
                          final value = v ?? '';
                          if (value.isEmpty) return 'Podaj hasło.';
                          if (_register && value.length < 8) {
                            return 'Hasło musi mieć min. 8 znaków.';
                          }
                          return null;
                        },
                      ),
                      AnimatedSize(
                        duration: Motion.toggle,
                        curve: Motion.curve,
                        alignment: Alignment.topCenter,
                        child: _register
                            ? Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: TextFormField(
                                  controller: _repeat,
                                  enabled: !_busy,
                                  obscureText: _obscure,
                                  textInputAction: TextInputAction.done,
                                  onFieldSubmitted: (_) => _submit(),
                                  decoration: const InputDecoration(
                                    labelText: 'Powtórz hasło',
                                    prefixIcon: Icon(Icons.lock_outline),
                                  ),
                                  validator: (v) => v == _password.text
                                      ? null
                                      : 'Hasła nie są takie same.',
                                ),
                              )
                            : Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () =>
                                          Navigator.of(context).push(AppRoute(
                                            builder: (_) =>
                                                ForgotPasswordScreen(
                                              account: widget.account,
                                              initialEmail: _email.text.trim(),
                                            ),
                                          )),
                                  child: const Text('Nie pamiętam hasła'),
                                ),
                              ),
                      ),
                      ErrorBanner(_error),
                      const SizedBox(height: 20),
                      LoadingButton(
                        label: _register ? 'Utwórz konto' : 'Zaloguj się',
                        busyLabel:
                            _register ? 'Zakładanie konta…' : 'Logowanie…',
                        busy: _busy,
                        onPressed: _submit,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Działa z każdą skrzynką: Gmail, WP, Interia, O2 czy firmową.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
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
