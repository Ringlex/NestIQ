/// Adres, na który Viessmann odsyła po zalogowaniu. Musi być dodany w portalu
/// deweloperskim w ustawieniach klienta (My Dashboard).
const viessmannRedirectUri = 'nestiq://viessmann';
const viessmannCallbackScheme = 'nestiq';

class ViessmannException implements Exception {
  const ViessmannException(this.message, {this.status});

  final String message;
  final int? status;

  /// Limit zapytań wyczerpany albo chwilowo zablokowany.
  bool get isRateLimited => status == 429;

  /// Trzeba zalogować się ponownie.
  bool get needsLogin => status == 401 || status == 400;

  @override
  String toString() => message;
}

/// Dane zalogowanego konta ViCare.
class ViessmannTokens {
  const ViessmannTokens(
      {required this.accessToken,
      required this.refreshToken,
      required this.expiresAt});

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  /// Odnawiamy z zapasem, żeby żądanie nie trafiło na token tuż przed wygaśnięciem.
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 2)));
}

/// Gdzie jest piec: instalacja, brama (numer seryjny) i urządzenie.
class ViessmannDeviceRef {
  const ViessmannDeviceRef({
    required this.installationId,
    required this.gatewaySerial,
    required this.deviceId,
    required this.modelId,
  });

  factory ViessmannDeviceRef.fromJson(Map<String, dynamic> json) =>
      ViessmannDeviceRef(
        installationId: '${json['installationId']}',
        gatewaySerial: json['gatewaySerial'] as String,
        deviceId: json['deviceId'] as String,
        modelId: json['modelId'] as String? ?? '',
      );

  final String installationId;
  final String gatewaySerial;
  final String deviceId;
  final String modelId;

  Map<String, dynamic> toJson() => {
        'installationId': installationId,
        'gatewaySerial': gatewaySerial,
        'deviceId': deviceId,
        'modelId': modelId,
      };
}

/// Dozwolone wartości polecenia, wzięte z odpowiedzi API (nie z naszych założeń).
class NumberRange {
  const NumberRange({required this.min, required this.max, required this.step});

  final num min;
  final num max;
  final num step;
}

/// Polecenie wystawione przez API dla danej funkcji.
class FeatureCommand {
  const FeatureCommand(
      {required this.name,
      required this.uri,
      required this.executable,
      this.params = const {}});

  final String name;
  final String uri;
  final bool executable;
  final Map<String, Map<String, dynamic>> params;

  NumberRange? rangeOf(String param) {
    final c = (params[param]?['constraints'] as Map?)?.cast<String, dynamic>();
    if (c == null || c['min'] is! num || c['max'] is! num) return null;
    return NumberRange(
        min: c['min'] as num,
        max: c['max'] as num,
        step: (c['stepping'] as num?) ?? 1);
  }

  List<String>? enumOf(String param) =>
      ((params[param]?['constraints'] as Map?)?['enum'] as List?)
          ?.cast<String>();
}

/// Jedna funkcja urządzenia (np. `heating.dhw.temperature.main`).
class ViessmannFeature {
  const ViessmannFeature({
    required this.name,
    required this.properties,
    required this.commands,
    required this.isEnabled,
  });

  factory ViessmannFeature.fromJson(Map<String, dynamic> json) {
    final commands = <String, FeatureCommand>{};
    for (final e in ((json['commands'] as Map?) ?? const {}).entries) {
      final c = (e.value as Map).cast<String, dynamic>();
      commands['${e.key}'] = FeatureCommand(
        name: '${e.key}',
        uri: c['uri'] as String? ?? '',
        executable: c['isExecutable'] != false,
        params: {
          for (final p in ((c['params'] as Map?) ?? const {}).entries)
            '${p.key}': (p.value as Map).cast<String, dynamic>(),
        },
      );
    }
    return ViessmannFeature(
      name: json['feature'] as String,
      properties:
          ((json['properties'] as Map?) ?? const {}).cast<String, dynamic>(),
      commands: commands,
      isEnabled: json['isEnabled'] != false,
    );
  }

  final String name;
  final Map<String, dynamic> properties;
  final Map<String, FeatureCommand> commands;
  final bool isEnabled;

  /// Wartość z `properties.<key>.value`, np. liczba albo tekst.
  Object? valueOf(String key) {
    final p = properties[key];
    return p is Map ? p['value'] : null;
  }

  num? number(String key) {
    final v = valueOf(key);
    return v is num ? v : null;
  }

  String? text(String key) {
    final v = valueOf(key);
    return v is String ? v : null;
  }

  bool? flag(String key) {
    final p = properties[key];
    if (p is Map && p['value'] is bool) return p['value'] as bool;
    return null;
  }
}

class ConsumptionSummary {
  const ConsumptionSummary(
      {this.today,
      this.week,
      this.month,
      this.lastMonth,
      this.year,
      this.unit});

  final num? today;
  final num? week;
  final num? month;
  final num? lastMonth;
  final num? year;
  final String? unit;
}

class StatusMessage {
  const StatusMessage({required this.code, required this.time});

  final String code;
  final DateTime? time;
}

enum FaultKind {
  /// Blokada awaryjna (`device.lock.malfunction`).
  lock,

  /// Usterka z kodem (`device.messages.errors.raw`, jeśli piec ją udostępnia).
  error,

  /// Komunikat serwisowy (`device.messages.service.raw`).
  service,

  /// Komunikat informacyjny (`device.messages.info.raw`).
  info;

  /// Czy o takim zdarzeniu powiadamiamy. Komunikaty informacyjne tylko pokazujemy.
  bool get notifies => this != info;
}

/// Usterka lub komunikat pieca.
class HeatingFault {
  const HeatingFault({required this.kind, required this.code, this.time});

  final FaultKind kind;

  /// Kod z pieca, np. `F.1000`; dla blokady `LOCK`.
  final String code;
  final DateTime? time;

  /// Stały identyfikator zdarzenia: ten sam wpis nie wywołuje powiadomienia drugi raz.
  String get id => kind == FaultKind.lock
      ? 'lock'
      : '${kind.name}:$code:${time?.toUtc().toIso8601String() ?? ''}';
}

/// Stan pieca w postaci potrzebnej ekranowi; liczby `null`, gdy czujnik nie podaje wartości.
class HeatingState {
  const HeatingState({
    required this.fetchedAt,
    required this.features,
    this.dhwCurrent,
    this.dhwTarget,
    this.dhwMode,
    this.dhwComfort,
    this.heatingMode,
    this.activeProgram,
    this.supplyTemperature,
    this.boilerTemperature,
    this.burnerActive,
    this.modulation,
    this.burnerHours,
    this.burnerStarts,
    this.pumpPercent,
    this.malfunction = false,
    this.programTemperature,
    this.messages = const [],
    this.faults = const [],
    this.gasDhw,
    this.gasHeating,
    this.heatDhw,
    this.heatHeating,
    this.powerDhw,
    this.powerHeating,
  });

  final DateTime fetchedAt;
  final Map<String, ViessmannFeature> features;

  final num? dhwCurrent;
  final num? dhwTarget;
  final String? dhwMode;
  final bool? dhwComfort;
  final String? heatingMode;
  final String? activeProgram;
  final num? supplyTemperature;
  final num? boilerTemperature;
  final bool? burnerActive;
  final num? modulation;
  final num? burnerHours;
  final num? burnerStarts;
  final num? pumpPercent;
  final bool malfunction;
  final num? programTemperature;
  final List<StatusMessage> messages;

  /// Usterki i komunikaty do pokazania w osobnym ekranie, od najpoważniejszych.
  final List<HeatingFault> faults;

  /// Zdarzenia, o których powiadamiamy (bez komunikatów informacyjnych).
  List<HeatingFault> get alerts => [
        for (final f in faults)
          if (f.kind.notifies) f
      ];
  final ConsumptionSummary? gasDhw;
  final ConsumptionSummary? gasHeating;
  final ConsumptionSummary? heatDhw;
  final ConsumptionSummary? heatHeating;
  final ConsumptionSummary? powerDhw;
  final ConsumptionSummary? powerHeating;

  static const heatingModeFeature = 'heating.circuits.0.operating.modes.active';
  static const programNormalFeature =
      'heating.circuits.0.operating.programs.normal';
  static const circuitLevelsFeature = 'heating.circuits.0.temperature.levels';
  static const dhwModeFeature = 'heating.dhw.operating.modes.active';
  static const dhwTargetFeature = 'heating.dhw.temperature.main';

  FeatureCommand? command(String feature, String name) =>
      features[feature]?.commands[name];

  /// Zakres temperatury ciepłej wody z odpowiedzi API (u Ciebie 30–60 °C co 1 °C).
  NumberRange? get dhwRange =>
      command(dhwTargetFeature, 'setTargetTemperature')?.rangeOf('temperature');

  /// Zakres nastawy obiegu: dozwolony przez polecenie pieca, zawężony do poziomów
  /// temperatur obiegu (min/max), jeśli piec je podaje. U Ciebie to 20–80 °C.
  NumberRange? get circuitRange {
    final base = command(programNormalFeature, 'setTemperature')
        ?.rangeOf('targetTemperature');
    if (base == null) return null;
    final levels = features[circuitLevelsFeature];
    final lo = levels?.number('min');
    final hi = levels?.number('max');
    return NumberRange(
      min: lo == null ? base.min : (lo > base.min ? lo : base.min),
      max: hi == null ? base.max : (hi < base.max ? hi : base.max),
      step: base.step,
    );
  }

  List<String> get dhwModes =>
      command(dhwModeFeature, 'setMode')?.enumOf('mode') ??
      const ['comfort', 'eco', 'off'];

  List<String> get heatingModes =>
      command(heatingModeFeature, 'setMode')?.enumOf('mode') ??
      const ['heating', 'standby'];

  static HeatingState parse(List<Map<String, dynamic>> data, {DateTime? now}) {
    final features = {
      for (final j in data) j['feature'] as String: ViessmannFeature.fromJson(j)
    };

    ViessmannFeature? f(String name) => features[name];

    ConsumptionSummary? summary(String name) {
      final p = f(name)?.properties;
      if (p == null || p.isEmpty) return null;
      num? n(String k) => (p[k] is Map ? (p[k] as Map)['value'] : null) as num?;
      final unit = p.values
          .whereType<Map>()
          .map((m) => m['unit'])
          .whereType<String>()
          .firstOrNull;
      return ConsumptionSummary(
        today: n('currentDay'),
        week: n('lastSevenDays'),
        month: n('currentMonth'),
        lastMonth: n('lastMonth'),
        year: n('currentYear'),
        unit: unit,
      );
    }

    final messages = <StatusMessage>[];
    final raw = f('device.messages.status.raw')?.properties['entries'];
    final entries = raw is Map ? raw['value'] : raw;
    if (entries is List) {
      for (final e in entries.whereType<Map>()) {
        final code = e['errorCode'];
        if (code is String) {
          messages.add(StatusMessage(
              code: code,
              time: DateTime.tryParse('${e['timestamp']}')?.toLocal()));
        }
      }
    }

    final faults = <HeatingFault>[];
    if (f('device.lock.malfunction')?.flag('active') == true) {
      faults.add(const HeatingFault(kind: FaultKind.lock, code: 'LOCK'));
    }
    for (final (feature, kind) in const [
      ('device.messages.errors.raw', FaultKind.error),
      ('device.messages.service.raw', FaultKind.service),
      ('device.messages.info.raw', FaultKind.info),
    ]) {
      final raw = f(feature)?.properties['entries'];
      final list = raw is Map ? raw['value'] : raw;
      if (list is! List) continue;
      for (final e in list.whereType<Map>()) {
        final code = e['errorCode'];
        if (code is String) {
          faults.add(HeatingFault(
              kind: kind,
              code: code,
              time: DateTime.tryParse('${e['timestamp']}')?.toLocal()));
        }
      }
    }
    faults.sort((a, b) {
      final byKind = a.kind.index.compareTo(b.kind.index);
      if (byKind != 0) return byKind;
      return (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0));
    });

    final burnerStats = f('heating.burners.0.statistics');
    final programNormal = f('heating.circuits.0.operating.programs.normal');

    return HeatingState(
      fetchedAt: now ?? DateTime.now(),
      features: features,
      dhwCurrent: f('heating.dhw.sensors.temperature.hotWaterStorage')
              ?.number('value') ??
          f('heating.dhw.sensors.temperature.dhwCylinder')?.number('value'),
      dhwTarget: f(dhwTargetFeature)?.number('value'),
      dhwMode: f(dhwModeFeature)?.text('value'),
      dhwComfort: f('heating.dhw.comfort')?.flag('active'),
      heatingMode: f(heatingModeFeature)?.text('value'),
      activeProgram:
          f('heating.circuits.0.operating.programs.active')?.text('value'),
      supplyTemperature: f('heating.circuits.0.sensors.temperature.supply')
              ?.number('value') ??
          f('heating.boiler.sensors.temperature.commonSupply')?.number('value'),
      boilerTemperature: f('heating.boiler.temperature')?.number('value'),
      burnerActive: f('heating.burners.0')?.flag('active'),
      modulation: f('heating.burners.0.modulation')?.number('value'),
      burnerHours: burnerStats?.number('hours'),
      burnerStarts: burnerStats?.number('starts'),
      pumpPercent: f('heating.boiler.pumps.internal.target')?.number('value'),
      malfunction: f('device.lock.malfunction')?.flag('active') ?? false,
      programTemperature: programNormal?.number('temperature'),
      messages: messages,
      faults: faults,
      gasDhw: summary('heating.gas.consumption.summary.dhw'),
      gasHeating: summary('heating.gas.consumption.summary.heating'),
      heatDhw: summary('heating.heat.production.summary.dhw'),
      heatHeating: summary('heating.heat.production.summary.heating'),
      powerDhw: summary('heating.power.consumption.summary.dhw'),
      powerHeating: summary('heating.power.consumption.summary.heating'),
    );
  }
}
