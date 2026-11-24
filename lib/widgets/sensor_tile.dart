import 'package:flutter/material.dart';

import 'motion.dart';

/// `21,5°C` z polskim przecinkiem.
String formatTemperature(double value) =>
    '${value.toStringAsFixed(1).replaceAll('.', ',')}°C';

String formatHumidity(double value) => '${value.round()}%';

/// „przed chwilą”, „5 min temu”, „3 godz. temu”, „2 dni temu”.
String timeAgo(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'przed chwilą';
  if (d.inMinutes < 60) return '${d.inMinutes} min temu';
  if (d.inHours < 24) return '${d.inHours} godz. temu';
  return '${d.inDays} dni temu';
}

/// Kolor ikony i wartości zależny od temperatury: chłodno, komfortowo, ciepło.
Color temperatureAccent(double? value, ColorScheme scheme) {
  if (value == null) return scheme.onSecondaryContainer;
  if (value < 18) return const Color(0xFF3B82C4);
  if (value > 25) return const Color(0xFFE0762B);
  return scheme.primary;
}

/// Wilgotność poza przedziałem komfortu (30-60%) jest wyróżniona.
bool humidityOutOfComfort(double? value) =>
    value != null && (value < 30 || value > 60);

/// Kafelek czujnika: temperatura jako główna liczba, wilgotność i bateria w znaczkach.
/// Dotknięcie otwiera szczegóły i ustawienia ([onTap]).
class SensorTile extends StatelessWidget {
  const SensorTile(
      {super.key,
      required this.name,
      this.temperature,
      this.humidity,
      this.battery,
      this.updatedAt,
      this.available = true,
      this.onTap});

  final String name;
  final double? temperature;
  final double? humidity;
  final int? battery;
  final DateTime? updatedAt;
  final bool available;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lowBattery = battery != null && battery! <= 20;
    final accent = temperatureAccent(temperature, scheme);
    final status = !available
        ? 'Brak odczytu'
        : updatedAt != null
            ? timeAgo(updatedAt!, DateTime.now())
            : 'Odczyt…';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            AnimatedContainer(
              duration: Motion.toggle,
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: accent.withOpacity(available ? 0.14 : 0.06),
                  borderRadius: BorderRadius.circular(14)),
              child: Icon(Icons.thermostat,
                  size: 24, color: available ? accent : scheme.outline),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (humidity != null || battery != null) ...[
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      if (humidity != null)
                        _Chip(
                            icon: Icons.water_drop_outlined,
                            text: formatHumidity(humidity!),
                            warn: humidityOutOfComfort(humidity),
                            tooltip: humidityOutOfComfort(humidity)
                                ? (humidity! < 30
                                    ? 'Powietrze jest suche'
                                    : 'Powietrze jest wilgotne')
                                : 'Wilgotność'),
                      if (battery != null)
                        _Chip(
                            icon: lowBattery
                                ? Icons.battery_alert
                                : Icons.battery_full,
                            text: 'bateria $battery%',
                            warn: lowBattery,
                            tooltip: lowBattery
                                ? 'Bateria prawie rozładowana'
                                : 'Bateria'),
                    ]),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (temperature != null)
              Flexible(
                flex: 2,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(formatTemperature(temperature!),
                      style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: available ? accent : scheme.outline)),
                ),
              )
            else
              Text('–', style: theme.textTheme.headlineSmall),
            if (onTap != null)
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.icon,
      required this.text,
      required this.warn,
      required this.tooltip});

  final IconData icon;
  final String text;
  final bool warn;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = warn ? scheme.error : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: warn
              ? scheme.errorContainer.withOpacity(0.5)
              : scheme.surfaceContainerHighest.withOpacity(0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: color))),
        ]),
      ),
    );
  }
}
