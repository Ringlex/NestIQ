/// Region chmury Tuya – ten, w którym założono projekt na iot.tuya.com.
enum TuyaRegion {
  eu('eu', 'openapi.tuyaeu.com', 'Europa (centralna)'),
  euWest('eu-w', 'openapi-weaz.tuyaeu.com', 'Europa (zachodnia)'),
  us('us', 'openapi.tuyaus.com', 'Ameryka (zachodnia)'),
  usEast('us-e', 'openapi-ueaz.tuyaus.com', 'Ameryka (wschodnia)'),
  india('in', 'openapi.tuyain.com', 'Indie'),
  singapore('sg', 'openapi-sg.iotbing.com', 'Singapur'),
  china('cn', 'openapi.tuyacn.com', 'Chiny');

  const TuyaRegion(this.code, this.host, this.label);
  final String code;
  final String host;
  final String label;

  static TuyaRegion fromCode(String? code) =>
      values.firstWhere((r) => r.code == code, orElse: () => TuyaRegion.eu);
}

/// Jak łączyć się z włącznikami.
enum TuyaMode {
  /// W domu przez sieć lokalną, poza domem przez chmurę.
  auto('Automatycznie'),
  local('Tylko lokalnie'),
  cloud('Tylko chmura');

  const TuyaMode(this.label);
  final String label;

  static TuyaMode fromName(String? name) =>
      values.firstWhere((m) => m.name == name, orElse: () => TuyaMode.auto);
}

/// Którędy aktualnie sterujemy urządzeniem.
enum TuyaRoute { connecting, local, cloud, offline }

/// Dane projektu z iot.tuya.com (Cloud → Development → Overview).
class TuyaCloudCredentials {
  const TuyaCloudCredentials({
    required this.accessId,
    required this.accessSecret,
    this.region = TuyaRegion.eu,
  });

  factory TuyaCloudCredentials.fromJson(Map<String, dynamic> json) =>
      TuyaCloudCredentials(
        accessId: json['accessId'] as String,
        accessSecret: json['accessSecret'] as String,
        region: TuyaRegion.fromCode(json['region'] as String?),
      );

  final String accessId;
  final String accessSecret;
  final TuyaRegion region;

  Map<String, dynamic> toJson() => {
        'accessId': accessId,
        'accessSecret': accessSecret,
        'region': region.code
      };
}

/// Jeden przycisk włącznika (gang): punkt danych `dpId` i jego kod w chmurze.
class TuyaChannel {
  const TuyaChannel(
      {required this.dpId, required this.code, required this.name});

  factory TuyaChannel.fromJson(Map<String, dynamic> json) => TuyaChannel(
        dpId: json['dpId'] as int,
        code: json['code'] as String,
        name: json['name'] as String,
      );

  final int dpId;
  final String code;
  final String name;

  Map<String, dynamic> toJson() => {'dpId': dpId, 'code': code, 'name': name};
}

/// Co mierzy czujnik.
enum TuyaMetricKind { temperature, humidity, battery }

/// Jedna mierzona wielkość czujnika: kod w chmurze i skala (`wartość = surowa / 10^scale`).
class TuyaMetric {
  const TuyaMetric(
      {required this.kind, required this.code, this.dpId = 0, this.scale = 0});

  factory TuyaMetric.fromJson(Map<String, dynamic> json) => TuyaMetric(
        kind: TuyaMetricKind.values.firstWhere((k) => k.name == json['kind'],
            orElse: () => TuyaMetricKind.temperature),
        code: json['code'] as String,
        dpId: (json['dpId'] as num?)?.toInt() ?? 0,
        scale: (json['scale'] as num?)?.toInt() ?? 0,
      );

  final TuyaMetricKind kind;
  final String code;
  final int dpId;
  final int scale;

  double value(num raw) {
    var v = raw.toDouble();
    for (var i = 0; i < scale; i++) {
      v /= 10;
    }
    return v;
  }

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'code': code, 'dpId': dpId, 'scale': scale};
}

/// Ustawienie czujnika zapisywane przez chmurę (polecenie `commands`): liczba w zakresie
/// albo wybór z listy. `scale` jak w [TuyaMetric]: wartość = surowa / 10^scale.
class TuyaSetting {
  const TuyaSetting({
    required this.code,
    this.options = const [],
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.scale = 0,
    this.unit = '',
  });

  factory TuyaSetting.fromJson(Map<String, dynamic> json) => TuyaSetting(
        code: json['code'] as String,
        options: [for (final o in (json['options'] as List? ?? const [])) '$o'],
        min: (json['min'] as num?)?.toInt() ?? 0,
        max: (json['max'] as num?)?.toInt() ?? 100,
        step: (json['step'] as num?)?.toInt() ?? 1,
        scale: (json['scale'] as num?)?.toInt() ?? 0,
        unit: json['unit'] as String? ?? '',
      );

  final String code;

  /// Dozwolone wartości ustawienia wyboru (np. `c`, `f`); puste dla liczby.
  final List<String> options;
  final int min;
  final int max;
  final int step;
  final int scale;
  final String unit;

  bool get isChoice => options.isNotEmpty;

  double get _factor {
    var f = 1.0;
    for (var i = 0; i < scale; i++) {
      f *= 10;
    }
    return f;
  }

  double value(num raw) => raw / _factor;
  int raw(double value) => (value * _factor).round();

  Map<String, dynamic> toJson() => {
        'code': code,
        'options': options,
        'min': min,
        'max': max,
        'step': step,
        'scale': scale,
        'unit': unit,
      };
}

class TuyaDevice {
  const TuyaDevice({
    required this.id,
    required this.name,
    required this.localKey,
    this.version = '3.3',
    this.ip,
    this.category = '',
    this.channels = const [],
    this.metrics = const [],
    this.settings = const [],
  });

  factory TuyaDevice.fromJson(Map<String, dynamic> json) => TuyaDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        localKey: json['localKey'] as String,
        version: json['version'] as String? ?? '3.3',
        ip: json['ip'] as String?,
        category: json['category'] as String? ?? '',
        channels: [
          for (final c in (json['channels'] as List? ?? const []))
            TuyaChannel.fromJson((c as Map).cast<String, dynamic>()),
        ],
        metrics: [
          for (final m in (json['metrics'] as List? ?? const []))
            TuyaMetric.fromJson((m as Map).cast<String, dynamic>()),
        ],
        settings: [
          for (final m in (json['settings'] as List? ?? const []))
            TuyaSetting.fromJson((m as Map).cast<String, dynamic>()),
        ],
      );

  final String id;
  final String name;

  /// Klucz do szyfrowania w sieci lokalnej; wydaje go tylko chmura Tuya.
  final String localKey;

  /// 3.3, 3.4 lub 3.5. Wykrywany przy pierwszym połączeniu.
  final String version;

  /// Adres w sieci lokalnej; bez niego urządzenie działa tylko przez chmurę.
  final String? ip;
  final String category;
  final List<TuyaChannel> channels;

  /// Wielkości mierzone przez czujnik (temperatura, wilgotność, bateria).
  final List<TuyaMetric> metrics;

  /// Ustawienia czujnika, które chmura pozwala zapisać (progi alarmów, jednostka, raportowanie).
  final List<TuyaSetting> settings;

  /// Czujnik pokazujemy w zakładce Klimat; sama bateria przełącznika to za mało.
  bool get isSensor => metrics.any((m) => m.kind != TuyaMetricKind.battery);

  TuyaDevice copyWith({
    String? name,
    String? version,
    String? ip,
    bool clearIp = false,
    String? localKey,
    List<TuyaChannel>? channels,
    List<TuyaMetric>? metrics,
    List<TuyaSetting>? settings,
  }) =>
      TuyaDevice(
        id: id,
        name: name ?? this.name,
        localKey: localKey ?? this.localKey,
        version: version ?? this.version,
        ip: clearIp ? null : (ip ?? this.ip),
        category: category,
        channels: channels ?? this.channels,
        metrics: metrics ?? this.metrics,
        settings: settings ?? this.settings,
      );

  /// Nazwa wyświetlana dla przycisku: sama nazwa urządzenia, gdy jest jeden.
  String channelLabel(TuyaChannel channel) =>
      channels.length <= 1 ? name : '$name · ${channel.name}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'localKey': localKey,
        'version': version,
        'ip': ip,
        'category': category,
        'channels': [for (final c in channels) c.toJson()],
        'metrics': [for (final m in metrics) m.toJson()],
        'settings': [for (final m in settings) m.toJson()],
      };
}

/// Urządzenie znalezione w sieci przez rozgłoszenie UDP.
class TuyaDiscovered {
  const TuyaDiscovered(
      {required this.id, required this.ip, required this.version});

  final String id;
  final String ip;
  final String? version;
}
