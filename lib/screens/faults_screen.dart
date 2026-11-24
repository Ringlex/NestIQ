import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../viessmann/viessmann_controller.dart';
import '../viessmann/viessmann_faults.dart';
import '../viessmann/viessmann_models.dart';
import '../widgets/heating_cards.dart';
import '../widgets/motion.dart';

/// Usterki i komunikaty pieca: co się wydarzyło, kiedy i co zrobić.
/// Otwierany z zakładki Ogrzewanie oraz z powiadomienia o usterce.
class FaultsScreen extends StatefulWidget {
  const FaultsScreen({super.key, required this.viessmann});

  final ViessmannController viessmann;

  @override
  State<FaultsScreen> createState() => _FaultsScreenState();
}

class _FaultsScreenState extends State<FaultsScreen> {
  @override
  void initState() {
    super.initState();
    // Świeże dane: ekran często otwiera powiadomienie, a od ostatniego odczytu mogło minąć sporo czasu.
    scheduleMicrotask(() => widget.viessmann.refresh(force: true));
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.viessmann;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Usterki pieca'),
        actions: [
          ListenableBuilder(
            listenable: v,
            builder: (context, _) => IconButton(
              tooltip: 'Odśwież',
              onPressed: v.busy ? null : () => v.refresh(force: true),
              icon: v.busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: v,
        builder: (context, _) {
          final state = v.state;
          if (state == null) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: v.error != null
                  ? Center(child: Text(v.error!, textAlign: TextAlign.center))
                  : const Column(children: [
                      Skeleton(height: 140),
                      SizedBox(height: 12),
                      Skeleton(height: 140)
                    ]),
            );
          }
          final alerts = state.alerts;
          final infos = [
            for (final f in state.faults)
              if (!f.kind.notifies) f
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (v.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('${v.error} Pokazuję ostatni znany stan.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (alerts.isEmpty) _AllClear(readAt: state.fetchedAt),
              for (var i = 0; i < alerts.length; i++)
                FadeUp(index: i, child: FaultCard(fault: alerts[i])),
              if (infos.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Text('Informacje',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                for (final f in infos) FaultCard(fault: f),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Odczyt ${formatTime(state.fetchedAt)}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AllClear extends StatelessWidget {
  const _AllClear({required this.readAt});

  final DateTime readAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: FadeUp(
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.15),
                  shape: BoxShape.circle),
              child: Icon(Icons.check_circle_outline,
                  size: 32, color: Colors.green.shade700),
            ),
            const SizedBox(height: 16),
            Text('Brak usterek', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('Piec nie zgłasza usterek ani komunikatów serwisowych.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Karta jednej usterki: tytuł, czas, opis i wskazówka.
class FaultCard extends StatelessWidget {
  const FaultCard({super.key, required this.fault});

  final HeatingFault fault;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (bg, fg, icon) = switch (fault.kind) {
      FaultKind.lock => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.report_gmailerrorred_outlined
        ),
      FaultKind.error => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.error_outline
        ),
      FaultKind.service => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
          Icons.build_outlined
        ),
      FaultKind.info => (
          scheme.surfaceContainerHigh,
          scheme.onSurfaceVariant,
          Icons.info_outline
        ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration:
                        BoxDecoration(color: bg, shape: BoxShape.circle),
                    child: Icon(icon, color: fg, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(faultTitle(fault),
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        Text(
                          fault.time == null
                              ? faultKindLabel(fault.kind)
                              : '${faultKindLabel(fault.kind)} · ${formatTime(fault.time!)}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _Section(title: 'Co się stało', text: faultWhat(fault)),
              const SizedBox(height: 10),
              _Section(title: 'Co zrobić', text: faultAdvice(fault)),
              if (fault.kind != FaultKind.lock) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: fault.code));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(SnackBar(
                              content: Text('Skopiowano kod ${fault.code}')));
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text('Kopiuj kod ${fault.code}'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.primary)),
        const SizedBox(height: 2),
        Text(text, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
