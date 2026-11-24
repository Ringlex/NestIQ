import 'proto.dart';

/// Typy urządzeń Mobilus (wg integracji mobilus-client-home-assistant).
enum MobilusDeviceType {
  senso(1, 'SENSO'),
  cosmo(2, 'COSMO'),
  cmr(3, 'CMR'),
  cgr(4, 'CGR'),
  switchDevice(5, 'SWITCH'),
  switchNp(6, 'SWITCH NP'),
  cosmoCzr(7, 'COSMO CZR'),
  cosmoMzr(8, 'COSMO MZR'),
  sensoZ(9, 'SENSO Z'),
  unknown(-1, 'Nieznany');

  const MobilusDeviceType(this.code, this.label);
  final int code;
  final String label;

  static MobilusDeviceType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => unknown);

  bool get isCover =>
      const {senso, cosmo, cmr, cosmoCzr, cosmoMzr, sensoZ}.contains(this);
  bool get isGarage => this == cgr;
  bool get isSwitch => this == switchDevice || this == switchNp;
  bool get supportsPosition => this == senso || this == sensoZ;
  bool get supportsTilt => this == cosmoCzr;
}

/// Stan urządzenia odczytany z wartości zdarzenia, np. `UP`, `45%`, `DOWN:60$`.
class DeviceStatus {
  DeviceStatus(this.event);

  final DeviceEvent event;

  String get raw => event.value;
  bool get isMoving => event.eventNumber == DeviceEvent.movingEventNumber;

  String get _main => raw.split(':').first;
  String? get _extra => raw.contains(':') ? raw.split(':')[1] : null;

  static int? _percent(String? v, String suffix) {
    if (v == null || !v.endsWith(suffix) || v.length < 2) return null;
    return int.tryParse(v.substring(0, v.length - 1));
  }

  /// Pozycja rolety w %, 100 = całkowicie otwarta.
  int? get position {
    if (_main == 'UP') return 100;
    if (_main == 'DOWN') return 0;
    final main = _percent(_main, '%');
    if (main == null) return null;
    if (isMoving) return _percent(_extra, r'$') ?? main;
    return main;
  }

  int? get tilt {
    final main = _percent(_main, '%');
    if (main == null) return _percent(_extra, r'$');
    return isMoving ? main : _percent(_extra, r'$');
  }

  bool get isOn => _main == 'ON';

  String get label {
    if (isMoving) return 'W ruchu';
    final p = position;
    if (p == 100) return 'Otwarta';
    if (p == 0) return 'Zamknięta';
    if (p != null) return 'Otwarta w $p%';
    return switch (_main) {
      'ON' => 'Włączone',
      'OFF' => 'Wyłączone',
      'STOP' => 'Zatrzymana',
      _ => raw,
    };
  }
}
