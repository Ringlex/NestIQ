import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../devices/smart_device.dart';
import 'hue_models.dart';

class HueException implements DeviceControlException {
  const HueException(this.code);

  /// `network`, `auth`, `link_button` albo `invalid`.
  final String code;

  @override
  String get message => switch (code) {
        'network' =>
          'Nie można połączyć się z mostkiem Hue. Sprawdź, czy jest włączony i w tej samej sieci.',
        'auth' =>
          'Mostek Hue odrzucił klucz aplikacji. Połącz mostek ponownie w Ustawieniach.',
        'link_button' =>
          'Naciśnij okrągły przycisk na mostku Hue i spróbuj ponownie w ciągu 30 sekund.',
        _ => 'Mostek Hue odpowiedział nieoczekiwanie. Sprawdź adres.',
      };

  @override
  String toString() => 'HueException($code)';
}

/// Lokalne API Hue v2 (CLIP): HTTPS z nagłówkiem `hue-application-key`.
///
/// Mostek ma własny certyfikat, więc zwykła weryfikacja by go odrzuciła. Klient
/// akceptuje certyfikat tylko dla adresu mostka, z którym rozmawia, nigdy dla innych hostów.
class HueClient {
  HueClient(
      {http.Client Function(String host)? clientFor,
      http.Client? discoveryClient,
      this.timeout = const Duration(seconds: 4)})
      : _clientFor = clientFor ?? _pinnedClient,
        _discovery = discoveryClient ?? http.Client();

  final http.Client Function(String host) _clientFor;
  final http.Client _discovery;
  final Duration timeout;
  final Map<String, http.Client> _clients = {};

  static http.Client _pinnedClient(String host) => IOClient(
      HttpClient()..badCertificateCallback = (cert, h, port) => h == host);

  http.Client _client(String host) =>
      _clients.putIfAbsent(host, () => _clientFor(host));

  static String normalizeHost(String input) {
    var host = input.trim().replaceFirst(RegExp(r'^https?://'), '');
    final slash = host.indexOf('/');
    if (slash >= 0) host = host.substring(0, slash);
    return host;
  }

  Future<dynamic> _send(String method, String host, String path,
      {String? key, Object? body}) async {
    final request =
        http.Request(method, Uri(scheme: 'https', host: host, path: path))
          ..headers['content-type'] = 'application/json';
    if (key != null) request.headers['hue-application-key'] = key;
    if (body != null) request.body = jsonEncode(body);

    http.Response response;
    try {
      response = await http.Response.fromStream(
          await _client(host).send(request).timeout(timeout));
    } on Exception {
      throw const HueException('network');
    }
    if (response.statusCode == 401 || response.statusCode == 403)
      throw const HueException('auth');
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw const HueException('invalid');
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw const HueException('invalid');
    }
  }

  /// Mostki w tej samej sieci według usługi wykrywania Philips (wymaga internetu).
  Future<List<HueBridgeInfo>> discover() async {
    try {
      final response = await _discovery
          .get(Uri.parse('https://discovery.meethue.com'))
          .timeout(timeout);
      if (response.statusCode != 200) return const [];
      return [
        for (final b in jsonDecode(response.body) as List)
          if (b is Map && b['internalipaddress'] is String)
            HueBridgeInfo(
                id: (b['id'] ?? b['internalipaddress']).toString(),
                host: b['internalipaddress'] as String),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Paruje aplikację z mostkiem; wymaga wcześniejszego naciśnięcia przycisku na mostku.
  Future<HueBridge> pair(String input) async {
    final host = normalizeHost(input);
    if (host.isEmpty) throw const HueException('invalid');
    final json = await _send('POST', host, '/api',
        body: {'devicetype': 'nestiq#telefon', 'generateclientkey': true});
    if (json is! List || json.isEmpty || json.first is! Map)
      throw const HueException('invalid');
    final first = json.first as Map;
    final error = first['error'];
    if (error is Map) {
      throw HueException(error['type'] == 101 ? 'link_button' : 'invalid');
    }
    final key = (first['success'] as Map?)?['username'];
    if (key is! String) throw const HueException('invalid');
    final id = await _bridgeId(host, key) ?? host;
    return HueBridge(id: id, host: host, key: key);
  }

  Future<String?> _bridgeId(String host, String key) async {
    try {
      final json =
          await _send('GET', host, '/clip/v2/resource/bridge', key: key);
      final data = (json as Map)['data'] as List;
      return (data.first as Map)['bridge_id'] as String?;
    } on Exception {
      return null;
    }
  }

  /// Lampki z nazwami, stanem, jasnością i łącznością.
  Future<List<HueLight>> lights(HueBridge bridge) async {
    final results = await Future.wait([
      _send('GET', bridge.host, '/clip/v2/resource/light', key: bridge.key),
      // Łączność jest dodatkiem: bez niej lampki uznajemy za dostępne.
      _send('GET', bridge.host, '/clip/v2/resource/zigbee_connectivity',
              key: bridge.key)
          .catchError((_) => null),
    ]);
    final unreachable = <String>{};
    final connectivity = results[1];
    if (connectivity is Map && connectivity['data'] is List) {
      for (final c in connectivity['data'] as List) {
        if (c is Map && c['status'] != 'connected') {
          final owner = (c['owner'] as Map?)?['rid'];
          if (owner is String) unreachable.add(owner);
        }
      }
    }
    final json = results[0];
    if (json is! Map || json['data'] is! List)
      throw const HueException('invalid');
    return [
      for (final l in json['data'] as List)
        if (l is Map)
          HueLight(
            id: l['id'] as String,
            name: ((l['metadata'] as Map?)?['name'] as String?) ?? 'Lampa',
            on: (l['on'] as Map?)?['on'] == true,
            brightness: ((l['dimming'] as Map?)?['brightness'] as num?)
                ?.round()
                .clamp(1, 100),
            reachable: !unreachable.contains((l['owner'] as Map?)?['rid']),
          ),
    ];
  }

  Future<void> setOn(HueBridge bridge, String lightId, bool on) =>
      _put(bridge, lightId, {
        'on': {'on': on},
      });

  Future<void> setBrightness(HueBridge bridge, String lightId, int percent) =>
      _put(bridge, lightId, {
        'on': {'on': true},
        'dimming': {'brightness': percent.clamp(1, 100)},
      });

  Future<void> _put(
      HueBridge bridge, String lightId, Map<String, dynamic> body) async {
    final json = await _send(
        'PUT', bridge.host, '/clip/v2/resource/light/$lightId',
        key: bridge.key, body: body);
    if (json is Map &&
        json['errors'] is List &&
        (json['errors'] as List).isNotEmpty) {
      throw const HueException('invalid');
    }
  }
}
