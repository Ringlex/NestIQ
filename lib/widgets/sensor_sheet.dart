import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import 'sensor_tile.dart';

/// Szczegóły czujnika: odczyt, bateria i (dla administratora) ustawienia zapisywane w urządzeniu.
Future<void> showSensorSheet(
  BuildContext context, {
  required SmartSensor sensor,
  required bool canEdit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _SensorSheet(sensor: sensor, canEdit: canEdit),
  );
}

class _SensorSheet extends StatefulWidget {
  const _SensorSheet({required this.sensor, required this.canEdit});

  final SmartSensor sensor;
  final bool canEdit;

  @override
  State<_SensorSheet> createState() => _SensorSheetState();
}

class _SensorSheetState extends State<_SensorSheet> {
  /// Wartości zapisane w tej sesji arkusza, żeby suwak nie wracał na starą pozycję.
  final _values = <String, Object?>{};
  final _saving = <String>{};
  String? _error;

  Future<void> _save(SensorSetting setting, Object value) async {
    setState(() {
      _values[setting.code] = value;
      _saving.add(setting.code);
      _error = null;
    });
    try {
      await setting.set(value);
    } on DeviceControlException catch (e) {
      if (mounted) {
        setState(() {
          _values.remove(setting.code);
          _error = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _saving.remove(setting.code));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = widget.sensor;
    final accent = temperatureAccent(s.temperature, scheme);
    final lowBattery = s.battery != null && s.battery! <= 20;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.name, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
              !s.available
                  ? 'Brak odczytu'
                  : s.updatedAt != null
                      ? 'Odczyt ${timeAgo(s.updatedAt!, DateTime.now())}'
                      : 'Odczyt…',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: _Reading(
                icon: Icons.thermostat,
                label: 'Temperatura',
                value: s.temperature == null
                    ? '–'
                    : formatTemperature(s.temperature!),
                color: accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Reading(
                icon: Icons.water_drop_outlined,
                label: 'Wilgotność',
                value: s.humidity == null ? '–' : formatHumidity(s.humidity!),
                color: humidityOutOfComfort(s.humidity)
                    ? scheme.error
                    : scheme.primary,
              ),
            ),
            if (s.battery != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: _Reading(
                  icon: lowBattery ? Icons.battery_alert : Icons.battery_full,
                  label: 'Bateria',
                  value: '${s.battery}%',
                  color: lowBattery ? scheme.error : scheme.primary,
                ),
              ),
            ],
          ]),
          const SizedBox(height: 20),
          if (!widget.canEdit)
            Text('Ustawienia czujnika zmienia administrator.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant))
          else if (s.settings.isEmpty)
            Text(
                'Ten czujnik nie udostępnia ustawień. Jeśli dodałeś go niedawno, '
                'odśwież urządzenia z chmury w Ustawienia › Tuya.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant))
          else ...[
            Text('Ustawienia czujnika', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
                'Czujnik na baterii przyjmie zmianę przy następnym połączeniu, '
                'więc może to potrwać kilka minut.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
            ],
            const SizedBox(height: 8),
            for (final setting in s.settings)
              _SettingRow(
                setting: setting,
                value: _values.containsKey(setting.code)
                    ? _values[setting.code]
                    : setting.value,
                saving: _saving.contains(setting.code),
                onChanged: (v) => _save(setting, v),
              ),
          ],
        ],
      ),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700, color: color)),
          ),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _SettingRow extends StatefulWidget {
  const _SettingRow(
      {required this.setting,
      required this.value,
      required this.saving,
      required this.onChanged});

  final SensorSetting setting;
  final Object? value;
  final bool saving;
  final ValueChanged<Object> onChanged;

  @override
  State<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<_SettingRow> {
  double? _drag;

  String _format(double v) {
    final text = v == v.roundToDouble()
        ? v.round().toString()
        : v.toStringAsFixed(1).replaceAll('.', ',');
    final unit = widget.setting.unit;
    return unit.isEmpty ? text : '$text${unit == 'min' ? ' ' : ''}$unit';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final setting = widget.setting;

    final Widget control;
    String? shown;
    if (setting.isChoice) {
      control = SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [
          for (final o in setting.options)
            ButtonSegment(value: o.id, label: Text(o.label)),
        ],
        selected: {if (widget.value is String) widget.value as String},
        emptySelectionAllowed: true,
        onSelectionChanged:
            widget.saving ? null : (v) => widget.onChanged(v.first),
      );
    } else {
      final current = (_drag ??
              (widget.value is num ? (widget.value as num).toDouble() : null) ??
              setting.min)
          .clamp(setting.min, setting.max);
      final divisions =
          ((setting.max - setting.min) / setting.step).round().clamp(1, 1000);
      shown = widget.value == null && _drag == null
          ? 'nie ustawiono'
          : _format(current);
      control = Slider(
        value: current,
        min: setting.min,
        max: setting.max,
        divisions: divisions,
        label: _format(current),
        onChanged: widget.saving ? null : (v) => setState(() => _drag = v),
        onChangeEnd: (v) {
          widget.onChanged(v);
          setState(() => _drag = null);
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text(setting.label, style: theme.textTheme.bodyLarge)),
            if (widget.saving)
              const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else if (shown != null)
              Text(shown,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: scheme.primary)),
          ]),
          if (setting.hint != null)
            Text(setting.hint!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          control,
        ],
      ),
    );
  }
}
