import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'viessmann_models.dart';

const viessmannApi = 'https://api.viessmann-climatesolutions.com/iot/v2';

/// Wywołania API Viessmanna, których potrzebuje aplikacja; interfejs dla testów kontrolera.
abstract interface class ViessmannApi {
  Future<ViessmannDeviceRef> findHeatingDevice();
  Future<List<Map<String, dynamic>>> features(ViessmannDeviceRef ref);
  Future<void> execute(
      ViessmannDeviceRef ref, FeatureCommand command, Map<String, Object?> body,
      {String? feature});
}

/// Klient IoT API v2. [token] zwraca ważny token dostępu (odświeża go w razie potrzeby),
/// [onCall] liczy zapytania, bo dzienny limit to 1450.
class ViessmannClient implements ViessmannApi {
  ViessmannClient({required this.token, this.onCall, http.Client? client})
      : _http = client ?? http.Client();

  final Future<String> Function() token;
  final void Function()? onCall;
  final http.Client _http;

  Future<Map<String, dynamic>> _send(String method, String url,
      {Object? body}) async {
    final uri = Uri.parse(url);
    // Token nie może trafić nigdzie poza API Viessmanna, także gdy adres polecenia
    // przyszedł w odpowiedzi serwera.
    if (uri.host != Uri.parse(viessmannApi).host) {
      throw const ViessmannException(
          'Nieoczekiwany adres polecenia, przerywam.');
    }

    final headers = {
      'Authorization': 'Bearer ${await token()}',
      if (body != null) 'Content-Type': 'application/json',
    };
    onCall?.call();

    final http.Response response;
    try {
      response = method == 'POST'
          ? await _http
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 20))
          : await _http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const ViessmannException('Viessmann nie odpowiada.');
    } on Exception {
      throw const ViessmannException('Brak połączenia z Viessmannem.');
    }

    Map<String, dynamic> json = const {};
    try {
      final parsed = jsonDecode(utf8.decode(response.bodyBytes));
      if (parsed is Map<String, dynamic>) json = parsed;
    } catch (_) {}

    if (response.statusCode == 429) {
      throw const ViessmannException(
        'Viessmann zablokował zapytania: dzienny limit (1450) został wyczerpany. Spróbuj później.',
        status: 429,
      );
    }
    if (response.statusCode == 401) {
      throw const ViessmannException(
          'Sesja Viessmanna wygasła. Zaloguj się ponownie.',
          status: 401);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          json['message'] ?? json['error'] ?? 'HTTP ${response.statusCode}';
      throw ViessmannException('Viessmann: $message',
          status: response.statusCode);
    }
    return json;
  }

  @override
  Future<ViessmannDeviceRef> findHeatingDevice() async {
    final json = await _send(
        'GET', '$viessmannApi/equipment/installations?includeGateways=true');
    for (final inst in (json['data'] as List? ?? const []).whereType<Map>()) {
      for (final gw
          in (inst['gateways'] as List? ?? const []).whereType<Map>()) {
        for (final dev
            in (gw['devices'] as List? ?? const []).whereType<Map>()) {
          if (dev['deviceType'] == 'heating') {
            return ViessmannDeviceRef(
              installationId: '${inst['id']}',
              gatewaySerial: '${gw['serial']}',
              deviceId: '${dev['id']}',
              modelId: '${dev['modelId'] ?? ''}',
            );
          }
        }
      }
    }
    throw const ViessmannException(
        'Na tym koncie ViCare nie znaleziono pieca ani kotła.');
  }

  /// Wszystkie funkcje urządzenia jednym zapytaniem.
  @override
  Future<List<Map<String, dynamic>>> features(ViessmannDeviceRef ref) async {
    final json = await _send(
      'GET',
      '$viessmannApi/features/installations/${ref.installationId}/gateways/${ref.gatewaySerial}'
          '/devices/${ref.deviceId}/features',
    );
    return (json['data'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  @override
  Future<void> execute(
    ViessmannDeviceRef ref,
    FeatureCommand command,
    Map<String, Object?> body, {
    String? feature,
  }) async {
    if (!command.executable) {
      throw const ViessmannException(
          'Piec nie przyjmuje teraz tego polecenia.');
    }
    final url = command.uri.isNotEmpty
        ? command.uri
        : '$viessmannApi/features/installations/${ref.installationId}/gateways/${ref.gatewaySerial}'
            '/devices/${ref.deviceId}/features/$feature/commands/${command.name}';
    final json = await _send('POST', url, body: body);

    final data = json['data'];
    if (data is Map && data['success'] == false) {
      throw ViessmannException(
          'Piec odrzucił polecenie: ${data['reason'] ?? 'nieznany powód'}');
    }
  }
}
