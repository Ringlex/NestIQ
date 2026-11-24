import 'package:flutter/material.dart';

import '../viessmann/viessmann_controller.dart';
import '../viessmann/viessmann_models.dart';
import '../widgets/heating_cards.dart';
import '../widgets/motion.dart';

/// Wykonuje zmianę w piecu i mówi użytkownikowi, jak poszło.
Future<void> _apply(
    BuildContext context, Future<void> Function() action, String done) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(done)));
  } on ViessmannException catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(e.message)));
  }
}

Future<bool> _confirm(
    BuildContext context, String title, String body, String action) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anuluj')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

class _DetailScaffold extends StatelessWidget {
  const _DetailScaffold(
      {required this.title, required this.viessmann, required this.builder});

  final String title;
  final ViessmannController viessmann;
  final Widget Function(BuildContext context, HeatingState state) builder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListenableBuilder(
        listenable: viessmann,
        builder: (context, _) {
          final state = viessmann.state;
          if (state == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(viessmann.error ?? 'Brak danych z pieca.',
                    textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (viessmann.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('${viessmann.error} Pokazuję ostatni znany stan.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error)),
                ),
              builder(context, state),
            ],
          );
        },
      ),
    );
  }
}

/// Ciepła woda: temperatura docelowa i tryb.
class HotWaterScreen extends StatelessWidget {
  const HotWaterScreen(
      {super.key, required this.viessmann, required this.canControl});

  final ViessmannController viessmann;
  final bool canControl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _DetailScaffold(
      title: 'Ciepła woda',
      viessmann: viessmann,
      builder: (context, state) {
        final off = state.dhwMode == 'off';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FadeUp(
              child: HeatingCard(
                title: 'Temperatura',
                icon: Icons.water_drop_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Metric(value: state.dhwCurrent, label: 'Teraz w zasobniku'),
                    const SizedBox(height: 16),
                    if (state.dhwRange == null || state.dhwTarget == null)
                      Text('Piec nie udostępnia ustawiania temperatury.',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant))
                    else ...[
                      TemperatureEditor(
                        label: 'Temperatura docelowa',
                        value: state.dhwTarget!,
                        range: state.dhwRange!,
                        enabled: canControl && !off && !viessmann.busy,
                        onSave: (t) => _apply(
                            context,
                            () => viessmann.setDhwTarget(t),
                            'Zapisano ${formatNumber(t)} °C. Piec potwierdzi zmianę za chwilę.'),
                      ),
                      if (off)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                              'Ciepła woda jest wyłączona. Włącz tryb poniżej, żeby zmienić temperaturę.',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FadeUp(
              index: 1,
              child: HeatingCard(
                title: 'Tryb',
                icon: Icons.tune,
                child: ModeChoice(
                  options: state.dhwModes,
                  selected: state.dhwMode,
                  labelOf: dhwModeLabel,
                  enabled: canControl && !viessmann.busy,
                  onSelected: (mode) async {
                    if (mode == 'off' &&
                        !await _confirm(
                            context,
                            'Wyłączyć ciepłą wodę?',
                            'Piec przestanie podgrzewać wodę w zasobniku, dopóki jej nie włączysz.',
                            'Wyłącz')) {
                      return;
                    }
                    if (context.mounted) {
                      await _apply(context, () => viessmann.setDhwMode(mode),
                          'Tryb: ${dhwModeLabel(mode)}.');
                    }
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Ogrzewanie: nastawa obiegu i tryb pracy.
class HeatingCircuitScreen extends StatelessWidget {
  const HeatingCircuitScreen(
      {super.key, required this.viessmann, required this.canControl});

  final ViessmannController viessmann;
  final bool canControl;

  /// Zmiana o tyle stopni lub więcej wymaga potwierdzenia.
  static const confirmDelta = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _DetailScaffold(
      title: 'Ogrzewanie',
      viessmann: viessmann,
      builder: (context, state) {
        final standby = state.heatingMode == 'standby';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FadeUp(
              child: HeatingCard(
                title: 'Nastawa obiegu',
                icon: Icons.local_fire_department_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Metric(
                        value: state.supplyTemperature,
                        label: 'Zasilanie teraz'),
                    const SizedBox(height: 16),
                    if (state.circuitRange == null ||
                        state.programTemperature == null)
                      Text('Piec nie udostępnia ustawiania nastawy.',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant))
                    else
                      TemperatureEditor(
                        label: 'Nastawa temperatury',
                        value: state.programTemperature!,
                        range: state.circuitRange!,
                        enabled: canControl && !standby && !viessmann.busy,
                        onSave: (t) async {
                          final from = state.programTemperature!;
                          if ((t - from).abs() >= confirmDelta &&
                              !await _confirm(
                                context,
                                'Duża zmiana nastawy',
                                'Zmienić nastawę z ${formatNumber(from)} °C na ${formatNumber(t)} °C? '
                                    'Wpływa to na ogrzewanie całego domu.',
                                'Zmień',
                              )) {
                            return;
                          }
                          if (context.mounted) {
                            await _apply(
                                context,
                                () => viessmann.setCircuitTemperature(t),
                                'Zapisano ${formatNumber(t)} °C. Piec potwierdzi zmianę za chwilę.');
                          }
                        },
                      ),
                    const SizedBox(height: 12),
                    Text(
                      standby
                          ? 'Ogrzewanie jest w czuwaniu. Włącz tryb poniżej, żeby zmienić nastawę.'
                          : 'To temperatura wody zasilającej obieg grzewczy: piec nie podaje temperatury w pomieszczeniu '
                              'ani na zewnątrz. Zmiana wpływa na ogrzewanie całego domu.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FadeUp(
              index: 1,
              child: HeatingCard(
                title: 'Tryb pracy',
                icon: Icons.tune,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ModeChoice(
                      options: state.heatingModes,
                      selected: state.heatingMode,
                      labelOf: heatingModeLabel,
                      enabled: canControl && !viessmann.busy,
                      onSelected: (mode) async {
                        if (mode == 'standby' &&
                            !await _confirm(
                                context,
                                'Przełączyć w czuwanie?',
                                'Ogrzewanie przestanie pracować. Ciepła woda działa według własnego trybu.',
                                'Czuwanie')) {
                          return;
                        }
                        if (context.mounted) {
                          await _apply(
                              context,
                              () => viessmann.setHeatingMode(mode),
                              'Tryb: ${heatingModeLabel(mode)}.');
                        }
                      },
                    ),
                    if (state.activeProgram != null) ...[
                      const SizedBox(height: 12),
                      Text(
                          'Aktywny program: ${programLabel(state.activeProgram!)}',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
