import 'package:flutter/material.dart';

import '../viessmann/viessmann_controller.dart';
import '../widgets/forms.dart';
import '../widgets/heating_cards.dart';
import '../widgets/motion.dart';
import '../viessmann/viessmann_faults.dart';
import '../viessmann/viessmann_models.dart';
import 'faults_screen.dart';
import 'heating_detail_screens.dart';
import '../widgets/responsive.dart';

/// Zawartość zakładki „Ogrzewanie”: ciepła woda, kocioł, zużycie, komunikaty.
class HeatingView extends StatelessWidget {
  const HeatingView({
    super.key,
    required this.viessmann,
    required this.canControl,
    required this.canManage,
    required this.onSetup,
  });

  final ViessmannController viessmann;
  final bool canControl;
  final bool canManage;
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = viessmann;

    if (!v.isConfigured) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: FadeUp(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                      color: scheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.local_fire_department_outlined,
                      size: 30, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(height: 16),
                Text('Połącz z piecem Viessmann',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  canManage
                      ? 'Zaloguj się kontem ViCare, żeby zobaczyć temperatury i zużycie oraz sterować ciepłą wodą.'
                      : 'Poproś administratora o połączenie aplikacji z piecem.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (canManage) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: onSetup,
                    style: FilledButton.styleFrom(shape: const StadiumBorder()),
                    child: const Text('Połącz z Viessmann'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final state = v.state;
    if (state == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: v.error != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ErrorBanner(v.error),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => v.refresh(force: true),
                    child: const Text('Spróbuj ponownie'),
                  ),
                ],
              )
            : const Column(children: [
                Skeleton(height: 170),
                SizedBox(height: 12),
                Skeleton(height: 150)
              ]),
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        if (v.sessionExpired)
          _Banner(
            icon: Icons.lock_clock_outlined,
            text: 'Sesja Viessmanna wygasła. Zaloguj się ponownie.',
            action: canManage ? 'Zaloguj' : null,
            onAction: onSetup,
          )
        else if (v.error != null)
          _Banner(
            icon: Icons.cloud_off_outlined,
            text: '${v.error} Pokazuję ostatni znany stan.',
            action: 'Ponów',
            onAction: () => v.refresh(force: true),
          ),
        if (state.alerts.isNotEmpty)
          _Banner(
            icon: Icons.warning_amber_rounded,
            text: state.alerts.length == 1
                ? '${faultTitle(state.alerts.first)}. Dotknij, aby zobaczyć szczegóły.'
                : 'Piec zgłasza ${state.alerts.length} usterek. Dotknij, aby zobaczyć szczegóły.',
            danger: state.alerts.any(
                (f) => f.kind == FaultKind.lock || f.kind == FaultKind.error),
            action: 'Zobacz',
            onAction: () => Navigator.of(context).push(AppRoute(
              builder: (_) => FaultsScreen(viessmann: v),
            )),
          ),
        FadeUp(
          child: HeatingCard(
            title: 'Ciepła woda',
            icon: Icons.water_drop_outlined,
            onTap: () => Navigator.of(context).push(AppRoute(
              builder: (_) =>
                  HotWaterScreen(viessmann: v, canControl: canControl),
            )),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                        child: Metric(
                            value: state.dhwCurrent,
                            label: 'Teraz w zasobniku')),
                    Expanded(
                        child:
                            Metric(value: state.dhwTarget, label: 'Nastawa')),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  state.dhwMode == null
                      ? 'Dotknij, aby zmienić'
                      : 'Tryb: ${dhwModeLabel(state.dhwMode!)}. Dotknij, aby zmienić.',
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
            title: 'Ogrzewanie',
            icon: Icons.local_fire_department_outlined,
            trailing: _BurnerChip(
                active: state.burnerActive, modulation: state.modulation),
            onTap: () => Navigator.of(context).push(AppRoute(
              builder: (_) =>
                  HeatingCircuitScreen(viessmann: v, canControl: canControl),
            )),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Nastawa to ta sama wartość, którą pokazuje ViCare przy obiegu grzewczym.
                    Expanded(
                        child: Metric(
                            value: state.programTemperature,
                            label: 'Nastawa obiegu')),
                    Expanded(
                        child: Metric(
                            value: state.supplyTemperature,
                            label: 'Zasilanie teraz')),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  [
                    if (state.heatingMode != null)
                      'Tryb: ${heatingModeLabel(state.heatingMode!)}',
                    if (state.activeProgram != null)
                      'Program: ${programLabel(state.activeProgram!)}',
                    'Dotknij, aby zmienić',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FadeUp(
          index: 2,
          child: HeatingCard(
            title: 'Usterki',
            icon: state.alerts.isEmpty
                ? Icons.check_circle_outline
                : Icons.report_gmailerrorred_outlined,
            onTap: () => Navigator.of(context).push(AppRoute(
              builder: (_) => FaultsScreen(viessmann: v),
            )),
            child: Text(
              state.alerts.isEmpty
                  ? 'Brak usterek. Dotknij, aby zobaczyć historię komunikatów.'
                  : state.alerts
                      .map((f) => f.kind == FaultKind.lock ? 'blokada' : f.code)
                      .join(', '),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FadeUp(
          index: 3,
          child: HeatingCard(
            title: 'Zużycie',
            icon: Icons.bar_chart_rounded,
            child: Column(
              children: [
                ConsumptionTable(rows: {
                  'Gaz, ogrzewanie': state.gasHeating,
                  'Gaz, c.w.u.': state.gasDhw
                }),
                const SizedBox(height: 8),
                ConsumptionTable(rows: {
                  'Ciepło, ogrzewanie': state.heatHeating,
                  'Ciepło, c.w.u.': state.heatDhw
                }),
                if (state.burnerHours != null &&
                    state.burnerStarts != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Palnik: ${formatNumber(state.burnerHours!, decimals: 0)} h pracy, '
                      '${formatNumber(state.burnerStarts!, decimals: 0)} uruchomień',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (state.messages.isNotEmpty) ...[
          const SizedBox(height: 12),
          FadeUp(
            index: 3,
            child: HeatingCard(
              title: 'Komunikaty pieca',
              icon: Icons.info_outline,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final m in state.messages.take(5))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Text(m.code,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const Spacer(),
                          if (m.time != null)
                            Text(formatTime(m.time!),
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text('To kody stanu pieca (priorytet „status”), nie awarie.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Odczyt ${formatTime(state.fetchedAt)} · zapytania do Viessmanna: ${v.callsLast24h} z ${ViessmannController.dailyLimit} na dobę',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              tooltip: 'Odśwież',
              onPressed: v.busy ? null : () => v.refresh(force: true),
              icon: v.busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
      ],
    );
  }
}

class _BurnerChip extends StatelessWidget {
  const _BurnerChip({required this.active, required this.modulation});

  final bool? active;
  final num? modulation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = active == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: on ? scheme.tertiaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        on
            ? 'Palnik pracuje${modulation == null ? '' : ' · ${formatNumber(modulation!, decimals: 0)}%'}'
            : 'Palnik wyłączony',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: on ? scheme.onTertiaryContainer : scheme.onSurfaceVariant),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(
      {required this.icon,
      required this.text,
      this.action,
      this.onAction,
      this.danger = false});

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = danger ? scheme.errorContainer : scheme.surfaceContainerHigh;
    final fg = danger ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 10),
            Expanded(
                child: Text(text,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: fg))),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ),
      ),
    );
  }
}
