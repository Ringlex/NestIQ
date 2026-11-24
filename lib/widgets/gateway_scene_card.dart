import 'package:flutter/material.dart';

import '../mobilus/proto.dart';

/// Karta sceny z bramki. Nieaktywna scena jest wyszarzona i ma obramowanie
/// zamiast wypełnienia, żeby od razu odróżniała się od aktywnych.
class GatewaySceneCard extends StatelessWidget {
  const GatewaySceneCard({
    super.key,
    required this.scene,
    required this.deviceNames,
    this.onRun,
    this.onTap,
  });

  final GatewayScene scene;
  final Map<int, String> deviceNames;

  /// `null` wyszarza przycisk – profil bez prawa uruchamiania scen.
  final VoidCallback? onRun;
  final VoidCallback? onTap;

  static String? scheduleLabel(GatewayScene scene) {
    if (scene.schedule.isEmpty) return null;
    String two(int v) => v.toString().padLeft(2, '0');
    final times = {
      for (final s in scene.schedule)
        '${two(s.localTime.hour)}:${two(s.localTime.minute)}'
    }.toList()
      ..sort();
    final days = {for (final s in scene.schedule) s.localDay};
    const names = [
      (1, 'pn'),
      (2, 'wt'),
      (3, 'śr'),
      (4, 'cz'),
      (5, 'pt'),
      (6, 'so'),
      (0, 'nd')
    ];
    final label = days.length == 7
        ? 'Codziennie'
        : [
            for (final (d, n) in names)
              if (days.contains(d)) n
          ].join(', ');
    return '$label · ${times.join(', ')}';
  }

  static String valueLabel(String value) => switch (value) {
        'UP' => '↑',
        'DOWN' => '↓',
        'STOP' => '■',
        'ON' => 'wł.',
        'OFF' => 'wył.',
        _ => value,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = scene.active;
    final schedule = scheduleLabel(scene);
    final muted = scheme.onSurfaceVariant;

    final details = Opacity(
      opacity: active ? 1 : 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: active
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                child: Icon(
                  schedule == null ? Icons.auto_awesome : Icons.schedule,
                  color: active ? scheme.onPrimaryContainer : muted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(scene.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: active ? FontWeight.w600 : null)),
                    const SizedBox(height: 4),
                    _StatusBadge(active: active),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (schedule != null)
            Row(
              children: [
                Icon(Icons.access_time, size: 16, color: muted),
                const SizedBox(width: 6),
                Text(schedule,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      decoration: active ? null : TextDecoration.lineThrough,
                    )),
              ],
            ),
          const SizedBox(height: 6),
          Text(
            [
              for (final e in scene.events)
                '${deviceNames[e.deviceId] ?? 'Urządzenie ${e.deviceId}'} ${valueLabel(e.value)}',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );

    return Card(
      color: active ? null : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side:
            active ? BorderSide.none : BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: details),
              IconButton.filledTonal(
                tooltip: 'Uruchom teraz',
                icon: const Icon(Icons.play_arrow),
                onPressed: onRun,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color:
            active ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(active ? Icons.check_circle : Icons.pause_circle_outline,
              size: 14, color: fg),
          const SizedBox(width: 4),
          Text(active ? 'Aktywna' : 'Nieaktywna',
              style: theme.textTheme.labelSmall?.copyWith(color: fg)),
        ],
      ),
    );
  }
}
