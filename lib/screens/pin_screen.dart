import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/account_controller.dart';
import '../account/account_models.dart';
import '../widgets/motion.dart';

/// Wpisanie PIN-u profilu. PIN sprawdza serwer, z blokadą po serii pomyłek.
class PinScreen extends StatefulWidget {
  const PinScreen({super.key, required this.account, required this.profile});

  final AccountController account;
  final Profile profile;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));
  String _pin = '';
  String? _message;
  bool _checking = false;
  bool _locked = false;
  bool _ok = false;

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  Future<void> _press(String digit) async {
    if (_checking || _locked || _ok || _pin.length >= 4) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += digit;
      _message = null;
    });
    if (_pin.length == 4) await _submit();
  }

  void _backspace() {
    if (_checking || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    setState(() => _checking = true);
    try {
      await widget.account.selectProfile(widget.profile.id, pin: _pin);
      if (!mounted) return;
      setState(() => _ok = true);
      HapticFeedback.lightImpact();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      _shake.forward(from: 0);
      setState(() {
        _message = e.code == 'locked'
            ? '${e.message}\nAlbo poproś administratora o reset PIN-u.'
            : e.message;
        _locked = e.code == 'locked';
        _checking = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (mounted) setState(() => _pin = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Klawisz kurczy się na niskim ekranie, żeby klawiatura się mieściła;
            // gdy mimo to zabraknie miejsca (duża czcionka), całość się przewija.
            final key =
                ((constraints.maxHeight - 340) / 4 - 12).clamp(52.0, 76.0);
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: IntrinsicHeight(child: _content(theme, scheme, key)),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _content(ThemeData theme, ColorScheme scheme, double keySize) {
    return Column(
      children: [
        FadeUp(child: ProfileAvatar(profile: widget.profile, size: 72)),
        const SizedBox(height: 12),
        FadeUp(
          index: 1,
          child: Text(
            'Cześć, ${widget.profile.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Podaj PIN, żeby wejść do profilu.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) => Transform.translate(
            offset: Offset(
                math.sin(_shake.value * math.pi * 6) * 10 * (1 - _shake.value),
                0),
            child: child,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: AnimatedScale(
                    scale: _pin.length > i ? 1.15 : 1,
                    duration: const Duration(milliseconds: 180),
                    curve: Motion.bounce,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _pin.length > i
                            ? scheme.primary
                            : Colors.transparent,
                        border: Border.all(
                          color:
                              _pin.length > i ? scheme.primary : scheme.outline,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(
            child: AnimatedSwitcher(
              duration: Motion.toggle,
              child: _ok
                  ? Row(
                      key: const ValueKey('ok'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, color: Colors.green.shade700),
                        const SizedBox(width: 8),
                        Text('Witaj!',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(color: Colors.green.shade700)),
                      ],
                    )
                  : Padding(
                      key: ValueKey(_message),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 6),
                      child: Text(_message ?? '',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.error)),
                    ),
            ),
          ),
        ),
        const Spacer(),
        _Keypad(
            onDigit: _press,
            onBackspace: _backspace,
            enabled: !_locked,
            size: keySize),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.onDigit,
    required this.onBackspace,
    required this.enabled,
    required this.size,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget digit(String d) => SizedBox.square(
          dimension: size,
          child: FilledButton.tonal(
            onPressed: enabled ? () => onDigit(d) : null,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
              backgroundColor: scheme.surfaceContainerHigh.withOpacity(0.7),
            ),
            child: Text(d,
                style: TextStyle(
                    fontSize: size * 0.37, fontWeight: FontWeight.w500)),
          ),
        );

    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final d in row)
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: digit(d)),
              ],
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox.square(dimension: size)),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: digit('0')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox.square(
                dimension: size,
                child: IconButton(
                  tooltip: 'Usuń cyfrę',
                  onPressed: onBackspace,
                  icon: const Icon(Icons.backspace_outlined, size: 26),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
