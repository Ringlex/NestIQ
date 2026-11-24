import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'tuya_models.dart';

class TuyaCloudException implements Exception {
  const TuyaCloudException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

/// Wywołania chmury Tuya używane przez aplikację; wydzielone, żeby kontroler
/// dało się testować bez sieci.
abstract interface class TuyaCloudApi {
  Future<List<TuyaDevice>> importDevices();
  Future<void> setSwitch(String deviceId, String code, bool on);

  /// Zapisuje ustawienie urządzenia: surowa liczba albo tekst opcji.
  Future<void> setValue(String deviceId, String code, Object value);
  Future<Map<String, bool>> switchStates(String deviceId);

  /// Wszystkie odczyty urządzenia: kod punktu danych -> surowa wartość.
  Future<Map<String, Object?>> deviceStatus(String deviceId);
}

/// Klient OpenAPI Tuya (podpis HMAC-SHA256 „nowym algorytmem” z 2021).
///
/// Dane projektu wpisuje użytkownik i zostają na jego telefonie (Keychain /
/// Keystore). Każdy dom ma własny projekt, więc w aplikacji nie ma wspólnego sekretu.
class TuyaCloudClient implements TuyaCloudApi {
  TuyaCloudClient({
    required this.credentials,
    http.Client? client,
    int Function()? clockMillis,
  })  : _http = client ?? http.Client(),
        _clock = clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final TuyaCloudCredentials credentials;
  final http.Client _http;
  final int Function() _clock;

  String? _token;
  int _tokenExpiresAt = 0;

  /// Podpis żądania: `HMAC-SHA256(secret, id + token + t + stringToSign)` wielkimi
  /// literami hex. [signedHeaders] (tylko `Content-type` przy POST) wchodzi do
  /// `stringToSign`, tak jak w referencyjnej bibliotece tinytuya.
  static String sign({
    required String clientId,
    required String secret,
    required String? token,
    required int timestamp,
    required String method,
    required String pathWithQuery,
    String body = '',
    Map<String, String> signedHeaders = const {},
  }) {
    final stringToSign = '$method\n'
        '${sha256.convert(utf8.encode(body))}\n'
        '${signedHeaders.entries.map((e) => '${e.key}:${e.value}\n').join()}\n'
        '$pathWithQuery';
    final payload = '$clientId${token ?? ''}$timestamp$stringToSign';
    return Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode(payload))
        .toString()
        .toUpperCase();
  }

  Future<String> _accessToken({bool force = false}) async {
    if (!force && _token != null && _clock() < _tokenExpiresAt) return _token!;
    final result = await _call('GET', '/v1.0/token',
        query: {'grant_type': '1'}, authorized: false);
    _token = result['access_token'] as String;
    final ttl = (result['expire_time'] as num?)?.toInt() ?? 7200;
    // Odnawiamy z zapasem, żeby żądanie nie trafiło na token tuż przed wygaśnięciem.
    _tokenExpiresAt = _clock() + (ttl - 120) * 1000;
    return _token!;
  }

  /// Zwraca pole `result` odpowiedzi; `success: false` rzuca [TuyaCloudException].
  Future<dynamic> _call(
    String method,
    String path, {
    Map<String, String> query = const {},
    Object? body,
    bool authorized = true,
    bool retried = false,
  }) async {
    final token = authorized ? await _accessToken() : null;
    final sorted = query.keys.toList()..sort();
    // Podpisujemy zapytanie bez kodowania procentowego, w kolejności alfabetycznej.
    final signedQuery = sorted.map((k) => '$k=${query[k]}').join('&');
    final sentQuery = sorted
        .map((k) => '$k=${Uri.encodeQueryComponent(query[k]!)}')
        .join('&');
    final bodyText = body == null ? '' : jsonEncode(body);
    final t = _clock();
    final signedHeaders = method == 'POST'
        ? {'Content-type': 'application/json'}
        : <String, String>{};

    final headers = {
      'client_id': credentials.accessId,
      'sign': sign(
        clientId: credentials.accessId,
        secret: credentials.accessSecret,
        token: token,
        timestamp: t,
        method: method,
        pathWithQuery: signedQuery.isEmpty ? path : '$path?$signedQuery',
        body: bodyText,
        signedHeaders: signedHeaders,
      ),
      't': '$t',
      'sign_method': 'HMAC-SHA256',
      if (token != null) 'access_token': token,
      if (method == 'POST') ...{
        'Content-type': 'application/json',
        'Signature-Headers': 'Content-type',
      },
    };

    final uri = Uri.parse(
        'https://${credentials.region.host}$path${sentQuery.isEmpty ? '' : '?$sentQuery'}');
    final http.Response response;
    try {
      response = method == 'POST'
          ? await _http
              .post(uri, headers: headers, body: bodyText)
              .timeout(const Duration(seconds: 15))
          : await _http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const TuyaCloudException('Chmura Tuya nie odpowiada');
    } on Exception {
      throw const TuyaCloudException('Brak połączenia z chmurą Tuya');
    }

    Map<String, dynamic> json;
    try {
      json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw TuyaCloudException(
          'Nieoczekiwana odpowiedź chmury Tuya (HTTP ${response.statusCode})');
    }

    if (json['success'] == true) return json['result'];

    final code = (json['code'] as num?)?.toInt();
    // 1010 = token wygasł albo unieważniony: raz odnawiamy i powtarzamy.
    if (code == 1010 && authorized && !retried) {
      await _accessToken(force: true);
      return _call(method, path, query: query, body: body, retried: true);
    }
    throw TuyaCloudException(_explain(code, json['msg'] as String?),
        code: code);
  }

  static String _explain(int? code, String? msg) {
    final suffix = code == null ? '' : ' (kod $code)';
    return switch (code) {
      1004 =>
        'Chmura Tuya odrzuciła podpis. Sprawdź Access ID, Access Secret i centrum danych$suffix.',
      1106 =>
        'Brak uprawnień do tego zasobu. Powiąż konto aplikacji Tuya z projektem '
            '(Devices → Link App Account)$suffix.',
      2406 => 'Brak uprawnień do tego urządzenia w projekcie Tuya$suffix.',
      // Dwa różne problemy o podobnym brzmieniu po stronie Tuya.
      28841002 =>
        'Subskrypcja usługi API w projekcie Tuya wygasła. Na iot.tuya.com przedłuż okres '
            'próbny usługi IoT Core$suffix.',
      28841105 =>
        'Projekt Tuya nie ma wykupionej wymaganej usługi API (np. IoT Core). '
            'Na iot.tuya.com włącz ją w projekcie: Service API$suffix.',
      _ => 'Chmura Tuya: ${msg ?? 'nieznany błąd'}$suffix',
    };
  }

  // ---------------------------------------------------------------- API

  /// Wszystkie urządzenia powiązanych kont aplikacji Tuya / Smart Life, tylko te z przełącznikami.
  @override
  Future<List<TuyaDevice>> importDevices() async {
    final raw = <Map<String, dynamic>>[];
    String? lastRowKey;
    for (var page = 0; page < 20; page++) {
      final result =
          await _call('GET', '/v1.0/iot-01/associated-users/devices', query: {
        'size': '50',
        if (lastRowKey != null) 'last_row_key': lastRowKey,
      }) as Map<String, dynamic>;
      raw.addAll((result['devices'] as List? ?? const [])
          .cast<Map<String, dynamic>>());
      lastRowKey = result['last_row_key'] as String?;
      if (result['has_more'] != true || lastRowKey == null) break;
    }

    final devices = <TuyaDevice>[];
    for (final d in raw) {
      final id = d['id'] as String?;
      final key = d['local_key'] as String?;
      if (id == null || key == null || key.length != 16) continue;
      final spec = await _call('GET', '/v1.1/devices/$id/specifications')
          as Map<String, dynamic>;
      final channels = switchChannels(spec);
      final metrics = sensorMetrics(spec);
      final settings = metrics.any((m) => m.kind != TuyaMetricKind.battery)
          ? sensorSettings(spec)
          : const <TuyaSetting>[];
      // Bez przycisków i bez odczytów nie mamy czego pokazać.
      if (channels.isEmpty &&
          !metrics.any((m) => m.kind != TuyaMetricKind.battery)) continue;
      devices.add(TuyaDevice(
        id: id,
        name: (d['name'] as String?)?.trim().isNotEmpty == true
            ? d['name'] as String
            : id,
        localKey: key,
        category: d['category'] as String? ?? '',
        channels: channels,
        metrics: metrics,
        settings: settings,
      ));
    }
    return devices;
  }

  /// Przyciski włącznika z opisu urządzenia: logiczne punkty danych `switch*`
  /// (bez podświetlenia i innych przełączników pomocniczych).
  static List<TuyaChannel> switchChannels(Map<String, dynamic> spec) {
    final byCode = <String, int>{};
    for (final list in [spec['functions'], spec['status']]) {
      for (final item in (list as List? ?? const [])) {
        final m = (item as Map).cast<String, dynamic>();
        final code = m['code'] as String?;
        final type = (m['type'] as String?)?.toLowerCase();
        if (code == null || type != 'boolean') continue;
        final match = RegExp(r'^switch(?:_led)?(?:_(\d+))?$').firstMatch(code);
        if (match == null) continue;
        final dp =
            (m['dp_id'] as num?)?.toInt() ?? _defaultDp(code, match.group(1));
        byCode.putIfAbsent(code, () => dp);
      }
    }
    final codes = byCode.keys.toList()
      ..sort((a, b) => byCode[a]!.compareTo(byCode[b]!));
    return [
      for (var i = 0; i < codes.length; i++)
        TuyaChannel(
            dpId: byCode[codes[i]]!, code: codes[i], name: 'Przycisk ${i + 1}'),
    ];
  }

  static const _metricCodes = {
    TuyaMetricKind.temperature: [
      'va_temperature',
      'temp_current',
      'temp_indoor'
    ],
    TuyaMetricKind.humidity: [
      'va_humidity',
      'humidity_value',
      'humidity_current'
    ],
    TuyaMetricKind.battery: ['battery_percentage'],
  };

  /// Odczyty czujnika z opisu urządzenia: temperatura, wilgotność i bateria,
  /// z dokładnością (`scale`) z opisu wartości.
  static List<TuyaMetric> sensorMetrics(Map<String, dynamic> spec) {
    final byCode = <String, Map<String, dynamic>>{};
    for (final item in (spec['status'] as List? ?? const [])) {
      final m = (item as Map).cast<String, dynamic>();
      final code = m['code'] as String?;
      if (code != null && (m['type'] as String?)?.toLowerCase() == 'integer')
        byCode[code] = m;
    }
    final metrics = <TuyaMetric>[];
    for (final entry in _metricCodes.entries) {
      for (final code in entry.value) {
        final m = byCode[code];
        if (m == null) continue;
        var values = m['values'];
        if (values is String) {
          try {
            values = jsonDecode(values);
          } catch (_) {
            values = null;
          }
        }
        metrics.add(TuyaMetric(
          kind: entry.key,
          code: code,
          dpId: (m['dp_id'] as num?)?.toInt() ?? 0,
          scale: values is Map ? (values['scale'] as num?)?.toInt() ?? 0 : 0,
        ));
        break; // pierwszy pasujący kod według kolejności ważności
      }
    }
    return metrics;
  }

  /// Kody ustawień, które znamy i umiemy opisać po polsku; reszta funkcji urządzenia
  /// (podświetlenie, tryby serwisowe) zostaje poza aplikacją.
  static const settingCodes = [
    'temp_unit_convert',
    'maxtemp_set',
    'minitemp_set',
    'maxhum_set',
    'minihum_set',
    'temp_sensitivity',
    'hum_sensitivity',
    'temp_periodic_report',
    'hum_periodic_report',
  ];

  /// Ustawienia czujnika z listy `functions` (to, co wolno zapisać), z zakresami z opisu.
  static List<TuyaSetting> sensorSettings(Map<String, dynamic> spec) {
    final found = <String, TuyaSetting>{};
    for (final item in (spec['functions'] as List? ?? const [])) {
      final m = (item as Map).cast<String, dynamic>();
      final code = m['code'] as String?;
      if (code == null || !settingCodes.contains(code)) continue;
      var values = m['values'];
      if (values is String) {
        try {
          values = jsonDecode(values);
        } catch (_) {
          values = null;
        }
      }
      final v = values is Map ? values.cast<String, dynamic>() : const {};
      final type = (m['type'] as String?)?.toLowerCase();
      if (type == 'enum') {
        final range = [for (final o in (v['range'] as List? ?? const [])) '$o'];
        if (range.length >= 2) {
          found[code] = TuyaSetting(code: code, options: range);
        }
      } else if (type == 'integer') {
        final min = (v['min'] as num?)?.toInt();
        final max = (v['max'] as num?)?.toInt();
        if (min == null || max == null || max <= min) continue;
        found[code] = TuyaSetting(
          code: code,
          min: min,
          max: max,
          step: ((v['step'] as num?)?.toInt() ?? 1).clamp(1, max - min),
          scale: (v['scale'] as num?)?.toInt() ?? 0,
          unit: v['unit'] as String? ?? '',
        );
      }
    }
    return [
      for (final code in settingCodes)
        if (found[code] case final s?) s,
    ];
  }

  static int _defaultDp(String code, String? index) {
    if (index != null) return int.parse(index);
    return code == 'switch_led' ? 20 : 1;
  }

  @override
  Future<void> setSwitch(String deviceId, String code, bool on) async {
    await _call('POST', '/v1.0/iot-03/devices/$deviceId/commands', body: {
      'commands': [
        {'code': code, 'value': on},
      ],
    });
  }

  @override
  Future<void> setValue(String deviceId, String code, Object value) async {
    await _call('POST', '/v1.0/iot-03/devices/$deviceId/commands', body: {
      'commands': [
        {'code': code, 'value': value},
      ],
    });
  }

  @override
  Future<Map<String, Object?>> deviceStatus(String deviceId) async {
    final result =
        await _call('GET', '/v1.0/iot-03/devices/$deviceId/status') as List;
    return {
      for (final item in result.cast<Map<String, dynamic>>())
        item['code'] as String: item['value'],
    };
  }

  @override
  Future<Map<String, bool>> switchStates(String deviceId) async {
    final result =
        await _call('GET', '/v1.0/iot-03/devices/$deviceId/status') as List;
    return {
      for (final item in result.cast<Map<String, dynamic>>())
        if (item['value'] is bool)
          item['code'] as String: item['value'] as bool,
    };
  }
}
