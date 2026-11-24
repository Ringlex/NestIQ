import 'package:flutter/material.dart';

/// Błąd sterowania urządzeniem z komunikatem dla użytkownika.
abstract interface class DeviceControlException implements Exception {
  String get message;
}

/// Światło z dowolnej marki, sprowadzone do tego, czego potrzebuje ekran Dom.
class SmartLight {
  const SmartLight({
    required this.key,
    required this.name,
    required this.on,
    required this.status,
    required this.available,
    required this.set,
    this.icon,
    this.brightness,
    this.setBrightness,
  });

  /// Klucz do przypisania do pokoju (patrz `RoomsController`).
  final String key;
  final String name;

  /// `null` – stan jeszcze nieznany.
  final bool? on;
  final String status;
  final bool available;
  final IconData? icon;
  final Future<void> Function(bool value) set;

  /// Jasność w % (1-100); `null` gdy światło nie reguluje jasności.
  final int? brightness;
  final Future<void> Function(int percent)? setBrightness;
}

/// Roleta, brama albo markiza z dowolnej marki.
class SmartCover {
  const SmartCover({
    required this.key,
    required this.name,
    required this.status,
    required this.available,
    required this.command,
    this.position,
    this.moving = false,
    this.supportsPosition = true,
  });

  final String key;
  final String name;
  final String status;
  final bool available;

  /// Pozycja w %, 100 = całkowicie otwarta; `null` gdy nieznana.
  final int? position;
  final bool moving;
  final bool supportsPosition;

  /// Polecenia jak w aplikacji: `UP`, `DOWN`, `STOP` albo `NN%` (otwarcie w procentach).
  final Future<void> Function(String command) command;
}

/// Jedna opcja ustawienia wyboru (np. °C / °F).
class SensorOption {
  const SensorOption(this.id, this.label);
  final String id;
  final String label;
}

/// Ustawienie czujnika zapisywane w urządzeniu: liczba w zakresie albo wybór z listy.
///
/// Marka opisuje ustawienie, a ekran tylko je rysuje, więc nowy typ czujnika
/// nie wymaga zmian w interfejsie.
class SensorSetting {
  const SensorSetting({
    required this.code,
    required this.label,
    required this.set,
    this.hint,
    this.unit = '',
    this.value,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.options = const [],
  });

  final String code;
  final String label;

  /// Jedno zdanie wyjaśnienia pod nazwą.
  final String? hint;
  final String unit;

  /// Bieżąca wartość: `double` dla liczby, `String` (id opcji) dla wyboru; `null`, gdy nieznana.
  final Object? value;
  final double min;
  final double max;
  final double step;

  /// Niepusta lista oznacza ustawienie wyboru, pusta - liczbę.
  final List<SensorOption> options;

  bool get isChoice => options.isNotEmpty;

  /// Zapisuje wartość (`double` albo id opcji); rzuca [DeviceControlException].
  final Future<void> Function(Object value) set;
}

/// Czujnik temperatury i wilgotności; ustawienia są opcjonalne.
class SmartSensor {
  const SmartSensor({
    required this.key,
    required this.name,
    required this.available,
    this.temperature,
    this.humidity,
    this.battery,
    this.updatedAt,
    this.settings = const [],
  });

  final String key;
  final String name;
  final bool available;

  /// Ustawienia, które da się zmienić w urządzeniu; puste, gdy czujnik ich nie udostępnia.
  final List<SensorSetting> settings;

  /// °C.
  final double? temperature;

  /// % wilgotności względnej.
  final double? humidity;

  /// % naładowania baterii.
  final int? battery;

  /// Kiedy odczyt pochodzi z urządzenia; `null` gdy nieznane.
  final DateTime? updatedAt;

  bool get hasReading => temperature != null || humidity != null;
}

/// Źródło urządzeń jednej marki. Ekran Dom, pokoje i ustawienia znają tylko ten
/// interfejs, więc nowa marka to nowa klasa, a nie zmiany w ekranach.
abstract interface class DeviceSource implements Listenable {
  /// Krótki stały identyfikator, np. `shelly`.
  String get id;

  /// Nazwa marki w ustawieniach.
  String get title;

  /// Opis stanu w ustawieniach, np. „Urządzeń: 3”.
  String get summary;

  bool get hasDevices;

  List<SmartLight> get lights;
  List<SmartCover> get covers;
  List<SmartSensor> get sensors;

  /// Odpytywanie stanu, dopóki aplikacja jest na wierzchu.
  void start();
  void stop();
  Future<void> refresh();

  /// Ekran dodawania urządzeń tej marki.
  Widget buildSetup(BuildContext context);
}
