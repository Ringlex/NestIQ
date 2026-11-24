import 'package:flutter/material.dart';

import '../viessmann/viessmann_models.dart';
import 'motion.dart';

/// Polskie nazwy trybów i programów pieca. Nieznane wartości pokazujemy tak, jak podał piec.
String dhwModeLabel(String mode) => switch (mode) {
      'comfort' => 'Komfort',
      'eco' => 'Eko',
      'off' => 'Wyłączona',
      _ => mode,
    };

String heatingModeLabel(String mode) => switch (mode) {
      'heating' => 'Ogrzewanie',
      'standby' => 'Czuwanie',
      _ => mode,
    };

String programLabel(String program) => switch (program) {
      'normal' => 'Normalny',
      'normalEnergySaving' => 'Normalny, oszczędzanie',
      'comfort' => 'Komfort',
      'comfortEnergySaving' => 'Komfort, oszczędzanie',
      'reduced' => 'Obniżony',
      'reducedEnergySaving' => 'Obniżony, oszczędzanie',
      'standby' => 'Czuwanie',
      'summerEco' => 'Lato eko',
      'forcedLastFromSchedule' => 'Wg harmonogramu',
      _ => program,
    };

String formatNumber(num value, {int decimals = 1}) {
  final text = value.toStringAsFixed(decimals);
  final trimmed =
      text.contains('.') ? text.replaceFirst(RegExp(r'\.?0+$'), '') : text;
  return trimmed.replaceFirst('.', ',');
}

String formatTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.day)}.${two(time.month)} ${two(time.hour)}:${two(time.minute)}';
}

class HeatingCard extends StatelessWidget {
  const HeatingCard({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.onTap,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  /// Karta jest przyciskiem prowadzącym do ekranu szczegółów.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Przy dużej czcionce plakietka nie mieści się obok tytułu, więc schodzi pod niego.
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 22, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (trailing != null && !stacked) Flexible(child: trailing!),
                  if (onTap != null) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right,
                        color: theme.colorScheme.onSurfaceVariant),
                  ],
                ],
              ),
              if (trailing != null && stacked)
                Padding(
                    padding: const EdgeInsets.only(top: 8), child: trailing!),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Duża liczba z podpisem, np. „49,6 °C / Zasobnik”.
class Metric extends StatelessWidget {
  const Metric(
      {super.key, required this.value, required this.label, this.unit = '°C'});

  final num? value;
  final String label;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value == null ? '—' : '${formatNumber(value!)} $unit',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// Wybór jednego z kilku trybów; wartości pochodzą z poleceń pieca.
class ModeChoice extends StatelessWidget {
  const ModeChoice({
    super.key,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.enabled = true,
  });

  final List<String> options;
  final String? selected;
  final String Function(String) labelOf;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          ChoiceChip(
            label: Text(labelOf(option)),
            selected: option == selected,
            onSelected: enabled && option != selected
                ? (_) => onSelected(option)
                : null,
          ),
      ],
    );
  }
}

/// Edytor temperatury: duża wartość, przyciski − i +, suwak i jawne „Zapisz”.
/// Nic nie jest wysyłane do pieca, dopóki użytkownik nie zatwierdzi zmiany,
/// więc przypadkowe dotknięcie suwaka niczego nie przestawia.
class TemperatureEditor extends StatefulWidget {
  const TemperatureEditor({
    super.key,
    required this.value,
    required this.range,
    required this.enabled,
    required this.onSave,
    this.label = 'Temperatura docelowa',
  });

  /// Wartość aktualnie ustawiona w piecu.
  final num value;
  final NumberRange range;
  final bool enabled;
  final String label;

  /// Zapisuje nową wartość; błąd wyjątkiem zostaje po stronie wywołującego.
  final Future<void> Function(num value) onSave;

  @override
  State<TemperatureEditor> createState() => _TemperatureEditorState();
}

class _TemperatureEditorState extends State<TemperatureEditor> {
  num? _pending;
  bool _saving = false;

  num get _shown => _pending ?? widget.value;

  bool get _changed => _pending != null && _pending != widget.value;

  num _clamp(num v) => v.clamp(widget.range.min, widget.range.max);

  void _set(num v) => setState(() => _pending = _clamp(v));

  @override
  void didUpdateWidget(TemperatureEditor old) {
    super.didUpdateWidget(old);
    // Piec potwierdził zmianę (odczyt zgadza się z tym, co chcieliśmy ustawić).
    if (_pending != null && widget.value == _pending) _pending = null;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_pending!);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = widget.range;
    final active = widget.enabled && !_saving;
    final steps = ((r.max - r.min) / r.step).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.label,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              tooltip: 'Mniej',
              onPressed:
                  active && _shown > r.min ? () => _set(_shown - r.step) : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.toggle,
                child: FittedBox(
                  key: ValueKey(_shown),
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${formatNumber(_shown)} °C',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: _changed ? scheme.primary : null,
                    ),
                  ),
                ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Więcej',
              onPressed:
                  active && _shown < r.max ? () => _set(_shown + r.step) : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        Slider(
          value: _shown.toDouble().clamp(r.min.toDouble(), r.max.toDouble()),
          min: r.min.toDouble(),
          max: r.max.toDouble(),
          divisions: steps > 0 ? steps : null,
          label: '${formatNumber(_shown)} °C',
          onChanged: active ? (v) => _set(v.round()) : null,
        ),
        Text(
          'Zakres: ${formatNumber(r.min)}–${formatNumber(r.max)} °C, krok ${formatNumber(r.step)}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        AnimatedSize(
          duration: Motion.toggle,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !_changed
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() => _pending = null),
                        child: const Text('Cofnij'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: widget.enabled && !_saving ? _save : null,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: const StadiumBorder()),
                          child: _saving
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5))
                              : Text('Zapisz ${formatNumber(_shown)} °C'),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// Zużycie dziś / 7 dni / miesiąc / rok dla ogrzewania i ciepłej wody.
class ConsumptionTable extends StatelessWidget {
  const ConsumptionTable({super.key, required this.rows});

  /// Etykieta wiersza → dane.
  final Map<String, ConsumptionSummary?> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final unitLabel = switch (rows.values
        .whereType<ConsumptionSummary>()
        .map((r) => r.unit)
        .firstOrNull) {
      'cubicMeter' => 'm³',
      'kilowattHour' => 'kWh',
      final other? => other,
      null => '',
    };

    String cell(num? v) => v == null ? '—' : formatNumber(v);

    Widget row(List<String> cells, {bool header = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(cells.first,
                    style: header ? muted : theme.textTheme.bodyMedium),
              ),
              for (final c in cells.skip(1))
                Expanded(
                  flex: 2,
                  child: Text(c,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: header ? muted : theme.textTheme.bodyMedium),
                ),
            ],
          ),
        );

    return Column(
      children: [
        row(['Zużycie ($unitLabel)', 'Dziś', '7 dni', 'Miesiąc', 'Rok'],
            header: true),
        for (final e in rows.entries)
          row([
            e.key,
            cell(e.value?.today),
            cell(e.value?.week),
            cell(e.value?.month),
            cell(e.value?.year)
          ]),
      ],
    );
  }
}
