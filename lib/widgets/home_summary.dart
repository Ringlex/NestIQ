import 'package:flutter/material.dart';

import 'device_tile.dart';
import 'sensor_tile.dart';

/// Stan domu jednym spojrzeniem: ile świateł świeci, ile rolet otwartych, czy jest usterka.
/// Każdy chip przenosi do właściwej zakładki.
class HomeSummary extends StatelessWidget {
  const HomeSummary({
    super.key,
    required this.lightsOn,
    required this.lightsTotal,
    required this.blindsOpen,
    required this.blindsTotal,
    this.malfunction = false,
    this.onLights,
    this.onBlinds,
    this.onHeating,
    this.averageTemperature,
    this.outdoorTemperature,
    this.onClimate,
  });

  final int lightsOn;
  final int lightsTotal;
  final int blindsOpen;
  final int blindsTotal;
  final bool malfunction;
  final VoidCallback? onLights;
  final VoidCallback? onBlinds;
  final VoidCallback? onHeating;

  /// Średnia z czujników temperatury; `null` gdy nie ma odczytów.
  final double? averageTemperature;
  final VoidCallback? onClimate;

  /// Temperatura na zewnątrz z prognozy pogody.
  final double? outdoorTemperature;

  bool get isEmpty =>
      lightsTotal == 0 &&
      blindsTotal == 0 &&
      !malfunction &&
      averageTemperature == null &&
      outdoorTemperature == null;

  static List<Widget> _spaced(List<Widget> chips) => [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          chips[i],
        ],
      ];

  @override
  Widget build(BuildContext context) {
    if (isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (lightBg, lightFg) =
        LightTile.colors(theme.brightness, lightsOn > 0, scheme);

    // Wszystkie znaczki w jednym wierszu bez przewijania: ikona i krótka wartość,
    // a pełny opis w podpowiedzi i dla czytników ekranu.
    Widget chip({
      required IconData icon,
      required String value,
      required String description,
      required Color bg,
      required Color fg,
      VoidCallback? onTap,
    }) =>
        Expanded(
          child: Tooltip(
            message: description,
            child: Semantics(
              button: true,
              label: description,
              excludeSemantics: true,
              child: Material(
                color: bg,
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onTap,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 18, color: fg),
                          if (value.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Text(value,
                                maxLines: 1,
                                softWrap: false,
                                style: theme.textTheme.labelLarge
                                    ?.copyWith(color: fg)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: _spaced([
          if (lightsTotal > 0)
            chip(
              icon: lightsOn > 0 ? Icons.lightbulb : Icons.lightbulb_outline,
              value: '$lightsOn/$lightsTotal',
              description: lightsOn == 0
                  ? 'Światła wyłączone'
                  : 'Świeci $lightsOn z $lightsTotal świateł',
              bg: lightBg,
              fg: lightFg,
              onTap: onLights,
            ),
          if (blindsTotal > 0)
            chip(
              icon: blindsOpen > 0 ? Icons.blinds : Icons.blinds_closed,
              value: '$blindsOpen/$blindsTotal',
              description: blindsOpen == 0
                  ? 'Rolety zamknięte'
                  : 'Otwartych $blindsOpen z $blindsTotal rolet',
              bg: scheme.primaryContainer,
              fg: scheme.onPrimaryContainer,
              onTap: onBlinds,
            ),
          if (outdoorTemperature != null)
            chip(
              icon: Icons.wb_sunny_outlined,
              value: _short(outdoorTemperature!),
              description:
                  'Na zewnątrz ${formatTemperature(outdoorTemperature!)}',
              bg: scheme.tertiaryContainer,
              fg: scheme.onTertiaryContainer,
              onTap: onClimate,
            ),
          if (averageTemperature != null)
            chip(
              icon: Icons.home_outlined,
              value: _short(averageTemperature!),
              description: 'W domu ${formatTemperature(averageTemperature!)}',
              bg: scheme.secondaryContainer,
              fg: scheme.onSecondaryContainer,
              onTap: onClimate,
            ),
          if (malfunction)
            chip(
              icon: Icons.warning_amber_rounded,
              value: '',
              description: 'Usterka ogrzewania',
              bg: scheme.errorContainer,
              fg: scheme.onErrorContainer,
              onTap: onHeating,
            ),
        ]),
      ),
    );
  }

  /// `21,5°` (jednostka jest w opisie).
  static String _short(double value) =>
      '${value.toStringAsFixed(1).replaceAll('.', ',')}°';
}
