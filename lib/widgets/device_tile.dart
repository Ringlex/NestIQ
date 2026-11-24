import 'package:flutter/material.dart';

import '../mobilus/device_info.dart';
import '../mobilus/proto.dart';
import 'motion.dart';

/// Wiersz światła: jeden przełącznik, z kolorem ikony zależnym od stanu.
/// Źródłem może być przełącznik Mobilus albo przycisk włącznika Tuya.
class LightTile extends StatelessWidget {
  const LightTile({
    super.key,
    required this.name,
    required this.on,
    required this.status,
    required this.enabled,
    required this.onChanged,
    this.trailingIcon,
    this.trailingTooltip,
    this.onDetails,
  });

  /// Przytrzymanie wiersza (szczegóły urządzenia); `null` wyłącza gest.
  final VoidCallback? onDetails;

  final String name;

  /// `null` – stan jeszcze nieznany.
  final bool? on;
  final String status;

  /// `false` wyszarza przełącznik (brak uprawnień albo urządzenie niedostępne).
  final bool enabled;
  final ValueChanged<bool> onChanged;

  /// Mała ikona drogi sterowania (sieć lokalna / chmura).
  final IconData? trailingIcon;
  final String? trailingTooltip;

  /// Bursztyn dla włączonego światła, osobny dla ciemnego motywu.
  static (Color bg, Color fg) colors(
      Brightness brightness, bool on, ColorScheme scheme) {
    if (!on) return (scheme.surfaceContainerHigh, scheme.onSurfaceVariant);
    return brightness == Brightness.dark
        ? (const Color(0xFF5A4300), const Color(0xFFFFD773))
        : (const Color(0xFFFFE3A8), const Color(0xFF7A5400));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isOn = on ?? false;
    final (iconBg, iconFg) = colors(theme.brightness, isOn, scheme);

    return InkWell(
      // Cały wiersz przełącza światło: większy cel niż sam przełącznik po prawej.
      onTap: enabled ? () => onChanged(!isOn) : null,
      onLongPress: onDetails,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            AnimatedContainer(
              duration: Motion.toggle,
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: iconBg, borderRadius: BorderRadius.circular(14)),
              child: Icon(isOn ? Icons.lightbulb : Icons.lightbulb_outline,
                  color: iconFg, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w500)),
                  Row(
                    children: [
                      if (trailingIcon != null) ...[
                        Tooltip(
                          message: trailingTooltip ?? '',
                          child: Icon(trailingIcon,
                              size: 14, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: AnimatedSwitcher(
                          duration: Motion.toggle,
                          child: Text(
                            status,
                            key: ValueKey(status),
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Semantics(
              label: name,
              child: Switch(value: isOn, onChanged: enabled ? onChanged : null),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wiersz rolety: góra/stop/dół i, gdy silnik to potrafi, suwak pozycji.
/// [enabled] = false wyszarza sterowanie, gdy profil nie ma uprawnień.
class DeviceTile extends StatefulWidget {
  const DeviceTile({
    super.key,
    required this.device,
    required this.status,
    required this.enabled,
    required this.onCommand,
    this.onDetails,
  });

  /// Przytrzymanie nagłówka rolety (szczegóły); `null` wyłącza gest.
  final VoidCallback? onDetails;

  final Device device;
  final DeviceStatus? status;
  final bool enabled;
  final ValueChanged<String> onCommand;

  @override
  State<DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<DeviceTile> {
  double? _dragOpen;

  MobilusDeviceType get _type => MobilusDeviceType.fromCode(widget.device.type);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = widget.status;
    final name = widget.device.name.isEmpty
        ? 'Urządzenie ${widget.device.id}'
        : widget.device.name;

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
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    status?.position == 0 ? Icons.blinds_closed : Icons.blinds,
                    color: scheme.onPrimaryContainer,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w500)),
                      AnimatedSwitcher(
                        duration: Motion.toggle,
                        child: Text(
                          status?.label ?? 'stan nieznany',
                          key: ValueKey(status?.raw),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                _coverButtons(),
              ],
            ),
          ),
          if (_type.supportsPosition) _positionSlider(),
        ],
      ),
    );
  }

  Widget _coverButtons() {
    final stop = _type.isGarage ? 'UP' : 'STOP';
    Widget button(IconData icon, String tooltip, String command) =>
        IconButton.filledTonal(
          tooltip: '${widget.device.name} – $tooltip',
          onPressed: widget.enabled ? () => widget.onCommand(command) : null,
          icon: Icon(icon),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Icons.keyboard_arrow_up_rounded, 'w górę', 'UP'),
        button(Icons.stop_rounded, 'stop', stop),
        button(Icons.keyboard_arrow_down_rounded, 'w dół', 'DOWN'),
      ],
    );
  }

  /// Suwak jak w aplikacji Mobilus: w lewo otwarta, w prawo zamknięta.
  Widget _positionSlider() {
    final open = (_dragOpen ?? widget.status?.position?.toDouble() ?? 0)
        .clamp(0, 100)
        .toDouble();
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: Slider(
        value: 100 - open,
        max: 100,
        divisions: 20,
        label: 'Otwarta w ${open.round()}%',
        onChanged:
            widget.enabled ? (v) => setState(() => _dragOpen = 100 - v) : null,
        onChangeEnd: widget.enabled
            ? (v) {
                widget.onCommand('${(100 - v).round()}%');
                setState(() => _dragOpen = null);
              }
            : null,
      ),
    );
  }
}

/// Pokój jako rozwijana sekcja z podsumowaniem w nagłówku.
class RoomSection extends StatelessWidget {
  const RoomSection({
    super.key,
    required this.title,
    required this.summary,
    required this.open,
    required this.onToggle,
    required this.children,
  });

  final String title;
  final String summary;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Flexible(
                    flex: 2,
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(summary,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: Motion.expand,
                    curve: Motion.bounce,
                    child:
                        Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: Motion.expand,
            curve: Motion.curve,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(children: children),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
