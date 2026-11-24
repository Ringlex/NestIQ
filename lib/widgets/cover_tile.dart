import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import 'motion.dart';

/// Wiersz rolety z dowolnej marki: góra/stop/dół i, gdy urządzenie zna pozycję, suwak.
class CoverTile extends StatefulWidget {
  const CoverTile(
      {super.key,
      required this.cover,
      required this.enabled,
      this.onDetails,
      this.onError});

  final SmartCover cover;
  final bool enabled;
  final VoidCallback? onDetails;
  final void Function(DeviceControlException error)? onError;

  @override
  State<CoverTile> createState() => _CoverTileState();
}

class _CoverTileState extends State<CoverTile> {
  double? _dragOpen;

  Future<void> _send(String command) async {
    try {
      await widget.cover.command(command);
    } on DeviceControlException catch (e) {
      widget.onError?.call(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cover = widget.cover;
    final active = widget.enabled && cover.available;

    Widget button(IconData icon, String tooltip, String command) =>
        IconButton.filledTonal(
          tooltip: '${cover.name} – $tooltip',
          onPressed: active ? () => _send(command) : null,
          icon: Icon(icon),
        );

    final open =
        (_dragOpen ?? cover.position?.toDouble() ?? 0).clamp(0, 100).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: widget.onDetails,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: Motion.toggle,
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(14)),
                  child: Icon(
                      cover.position == 0 ? Icons.blinds_closed : Icons.blinds,
                      color: scheme.onPrimaryContainer,
                      size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cover.name,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w500)),
                      AnimatedSwitcher(
                        duration: Motion.toggle,
                        child: Text(
                          cover.status,
                          key: ValueKey(cover.status),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    button(Icons.keyboard_arrow_up_rounded, 'w górę', 'UP'),
                    button(Icons.stop_rounded, 'stop', 'STOP'),
                    button(Icons.keyboard_arrow_down_rounded, 'w dół', 'DOWN'),
                  ],
                ),
              ],
            ),
          ),
          if (cover.supportsPosition)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Slider(
                value: 100 - open,
                max: 100,
                divisions: 20,
                label: 'Otwarta w ${open.round()}%',
                onChanged:
                    active ? (v) => setState(() => _dragOpen = 100 - v) : null,
                onChangeEnd: active
                    ? (v) {
                        _send('${(100 - v).round()}%');
                        setState(() => _dragOpen = null);
                      }
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}
