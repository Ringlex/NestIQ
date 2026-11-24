/// Połączony mostek Hue.
class HueBridge {
  const HueBridge({required this.id, required this.host, required this.key});

  factory HueBridge.fromJson(Map<String, dynamic> json) => HueBridge(
      id: json['id'] as String,
      host: json['host'] as String,
      key: json['key'] as String);

  /// Identyfikator mostka (stały po zmianie IP).
  final String id;
  final String host;

  /// Klucz aplikacji z parowania: pełny dostęp do mostka, więc trzymany w Keychain/Keystore.
  final String key;

  HueBridge withHost(String host) => HueBridge(id: id, host: host, key: key);

  Map<String, dynamic> toJson() => {'id': id, 'host': host, 'key': key};
}

/// Mostek znaleziony w sieci (przed sparowaniem).
class HueBridgeInfo {
  const HueBridgeInfo({required this.id, required this.host});

  final String id;
  final String host;
}

class HueLight {
  const HueLight({
    required this.id,
    required this.name,
    required this.on,
    this.brightness,
    this.reachable = true,
  });

  final String id;
  final String name;
  final bool on;

  /// 1-100; `null` dla lampek bez ściemniania.
  final int? brightness;

  /// `false`, gdy lampka straciła połączenie z mostkiem (np. wyłączona z prądu).
  final bool reachable;

  HueLight copyWith({bool? on, int? brightness}) => HueLight(
        id: id,
        name: name,
        on: on ?? this.on,
        brightness: brightness ?? this.brightness,
        reachable: reachable,
      );
}
