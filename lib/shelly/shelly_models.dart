enum ShellyKind {
  relay('Przekaźnik'),
  light('Światło'),
  cover('Roleta');

  const ShellyKind(this.label);
  final String label;

  static ShellyKind fromName(String? name) =>
      values.firstWhere((k) => k.name == name, orElse: () => ShellyKind.relay);
}

/// Jeden kanał urządzenia: przekaźnik, światło albo roleta.
class ShellyComponent {
  const ShellyComponent(this.kind, this.id);

  factory ShellyComponent.fromJson(Map<String, dynamic> json) =>
      ShellyComponent(ShellyKind.fromName(json['kind'] as String?),
          (json['id'] as num).toInt());

  final ShellyKind kind;
  final int id;

  /// Klucz w mapie stanów urządzenia.
  String get key => '${kind.name}:$id';

  Map<String, dynamic> toJson() => {'kind': kind.name, 'id': id};
}

class ShellyDevice {
  const ShellyDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.gen,
    required this.model,
    required this.components,
  });

  factory ShellyDevice.fromJson(Map<String, dynamic> json) => ShellyDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        gen: (json['gen'] as num).toInt(),
        model: json['model'] as String? ?? '',
        components: [
          for (final c in json['components'] as List)
            ShellyComponent.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );

  /// Adres MAC (stały nawet po zmianie IP); przy braku – adres hosta.
  final String id;
  final String name;
  final String host;

  /// 1 = starsze urządzenia (HTTP `/relay`, `/roller`), 2 = Plus/Pro (RPC).
  final int gen;
  final String model;
  final List<ShellyComponent> components;

  ShellyDevice copyWith(
          {String? name,
          String? host,
          int? gen,
          String? model,
          List<ShellyComponent>? components}) =>
      ShellyDevice(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        gen: gen ?? this.gen,
        model: model ?? this.model,
        components: components ?? this.components,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'gen': gen,
        'model': model,
        'components': [for (final c in components) c.toJson()],
      };
}

/// Odczytany stan kanału.
class ShellyState {
  const ShellyState({this.on, this.position, this.moving = false});

  /// Przekaźnik i światło.
  final bool? on;

  /// Roleta: pozycja w %, 100 = otwarta; `null` gdy nieskalibrowana.
  final int? position;
  final bool moving;

  ShellyState copyWith({bool? on, int? position, bool? moving}) => ShellyState(
      on: on ?? this.on,
      position: position ?? this.position,
      moving: moving ?? this.moving);
}
