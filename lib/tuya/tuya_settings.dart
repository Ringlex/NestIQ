import '../devices/smart_device.dart';
import 'tuya_models.dart';

/// Polskie nazwy i opisy znanych ustawień czujnika (kody Tuya `wsdcg` i pokrewne).
class _Label {
  const _Label(this.title, this.hint, [this.unit = '']);
  final String title;
  final String hint;
  final String unit;
}

const _labels = {
  'temp_unit_convert':
      _Label('Jednostka temperatury', 'Dotyczy wyświetlacza czujnika.'),
  'maxtemp_set': _Label('Alarm: za gorąco',
      'Czujnik zaalarmuje, gdy temperatura będzie wyższa.', '°C'),
  'minitemp_set': _Label('Alarm: za zimno',
      'Czujnik zaalarmuje, gdy temperatura będzie niższa.', '°C'),
  'maxhum_set':
      _Label('Alarm: za wilgotno', 'Alarm, gdy wilgotność będzie wyższa.', '%'),
  'minihum_set':
      _Label('Alarm: za sucho', 'Alarm, gdy wilgotność będzie niższa.', '%'),
  'temp_sensitivity': _Label('Czułość temperatury',
      'O ile musi się zmienić, żeby czujnik wysłał nowy odczyt.', '°C'),
  'hum_sensitivity': _Label('Czułość wilgotności',
      'O ile musi się zmienić, żeby czujnik wysłał nowy odczyt.', '%'),
  'temp_periodic_report': _Label(
      'Raport temperatury co', 'Rzadsze raporty oszczędzają baterię.', 'min'),
  'hum_periodic_report': _Label(
      'Raport wilgotności co', 'Rzadsze raporty oszczędzają baterię.', 'min'),
};

const _optionLabels = {'c': '°C', 'f': '°F'};

/// Zamienia ustawienie Tuya i jego bieżącą wartość (surową, z odczytu) na opis dla ekranu.
SensorSetting describeTuyaSetting(
  TuyaSetting setting, {
  required Object? current,
  required Future<void> Function(Object value) set,
}) {
  final label = _labels[setting.code] ?? _Label(setting.code, '');
  final unit = switch (setting.unit) {
    '' => label.unit,
    '℃' || 'C' || '°C' => '°C',
    final u => u,
  };
  if (setting.isChoice) {
    return SensorSetting(
      code: setting.code,
      label: label.title,
      hint: label.hint,
      value: current is String ? current : null,
      options: [
        for (final o in setting.options)
          SensorOption(o, _optionLabels[o.toLowerCase()] ?? o.toUpperCase()),
      ],
      set: set,
    );
  }
  return SensorSetting(
    code: setting.code,
    label: label.title,
    hint: label.hint,
    unit: unit,
    value: current is num ? setting.value(current) : null,
    min: setting.value(setting.min),
    max: setting.value(setting.max),
    step: setting.value(setting.step),
    set: set,
  );
}
