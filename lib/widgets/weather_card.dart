import 'package:flutter/material.dart';

import '../screens/planner/planner_common.dart';
import '../weather/weather_controller.dart';
import '../weather/weather_models.dart';
import 'sensor_tile.dart';

IconData weatherIcon(int code, {bool isDay = true}) => switch (code) {
      0 || 1 => isDay ? Icons.wb_sunny_outlined : Icons.nightlight_outlined,
      2 => isDay ? Icons.wb_cloudy_outlined : Icons.cloud_outlined,
      3 => Icons.cloud_outlined,
      45 || 48 => Icons.foggy,
      51 ||
      53 ||
      55 ||
      56 ||
      57 ||
      61 ||
      63 ||
      65 ||
      66 ||
      67 ||
      80 ||
      81 ||
      82 =>
        Icons.grain,
      71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
      95 || 96 || 99 => Icons.thunderstorm_outlined,
      _ => Icons.help_outline,
    };

/// Pogoda na zakładce Klimat: teraz i trzy kolejne dni, z nazwą miejscowości.
class WeatherCard extends StatelessWidget {
  const WeatherCard(
      {super.key, required this.weather, required this.onChangePlace});

  final WeatherController weather;
  final VoidCallback onChangePlace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final place = weather.place;
    final f = weather.forecast;
    if (place == null) return const SizedBox.shrink();

    final today = f?.days.firstOrNull;
    final next =
        f == null ? const <DayForecast>[] : f.days.skip(1).take(3).toList();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onChangePlace,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.place_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(place.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  if (weather.loading)
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(Icons.edit_outlined,
                        size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 12),
              if (f == null)
                Text(weather.error ?? 'Pobieranie pogody…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: weather.error != null
                            ? scheme.error
                            : scheme.onSurfaceVariant))
              else ...[
                Row(
                  children: [
                    Icon(weatherIcon(f.code, isDay: f.isDay),
                        size: 44, color: scheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(formatTemperature(f.temperature),
                              style: theme.textTheme.headlineMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(describeWeather(f.code),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                    if (today != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('↑ ${formatTemperature(today.max)}',
                              style: theme.textTheme.bodyMedium),
                          Text('↓ ${formatTemperature(today.min)}',
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    if (f.apparentTemperature != null)
                      'odczuwalna ${formatTemperature(f.apparentTemperature!)}',
                    if (f.windKmh != null) 'wiatr ${f.windKmh!.round()} km/h',
                    if (f.humidity != null)
                      'wilgotność ${formatHumidity(f.humidity!)}',
                    if (today?.precipitationChance != null)
                      'opady ${today!.precipitationChance}%',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (next.isNotEmpty) ...[
                  const Divider(height: 24),
                  Row(
                    children: [
                      for (final d in next)
                        Expanded(
                          child: Column(
                            children: [
                              Text(weekdayShort[d.date.weekday - 1],
                                  style: theme.textTheme.labelMedium?.copyWith(
                                      color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 4),
                              Icon(weatherIcon(d.code),
                                  size: 24, color: scheme.primary),
                              const SizedBox(height: 4),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                    '${d.max.round()}° / ${d.min.round()}°',
                                    style: theme.textTheme.bodySmall),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  [
                    if (weather.error != null)
                      'Nie udało się odświeżyć · dane sprzed ${timeAgo(f.fetchedAt, DateTime.now()).replaceAll(' temu', '')}'
                    else
                      'Zaktualizowano ${timeAgo(f.fetchedAt, DateTime.now())}',
                    'Dane: Open-Meteo.com',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: weather.error != null
                          ? scheme.error
                          : scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
