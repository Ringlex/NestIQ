import 'package:flutter/material.dart';

import 'motion.dart';

/// Komunikat błędu pod formularzem – wsuwa się płynnie, mówi co zrobić dalej.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: Motion.toggle,
      curve: Motion.curve,
      alignment: Alignment.topCenter,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: scheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(message!,
                          style: TextStyle(color: scheme.onErrorContainer)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Główny przycisk formularza: ze spinnerem w trakcie pracy, zablokowany, gdy [busy].
class LoadingButton extends StatelessWidget {
  const LoadingButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.busyLabel,
  });

  final String label;
  final String? busyLabel;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: const StadiumBorder(),
      ),
      child: AnimatedSwitcher(
        duration: Motion.toggle,
        child: busy
            ? Row(
                key: const ValueKey('busy'),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  if (busyLabel != null) ...[
                    const SizedBox(width: 12),
                    Text(busyLabel!)
                  ],
                ],
              )
            : Text(label, key: const ValueKey('idle')),
      ),
    );
  }
}

final emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
