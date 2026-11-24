import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../devices/smart_device.dart';
import 'somfy_models.dart';

class SomfyException implements DeviceControlException {
  const SomfyException(this.code);

  /// `network`, `auth`, `unsupported` albo `invalid`.
  final String code;

  @override
  String get message => switch (code) {
        'network' =>
          'Nie można połączyć się ze skrzynką Somfy. Sprawdź, czy jest włączona i w tej samej sieci. '
              'Jeśli podałeś numer PIN, spróbuj adresu IP skrzynki.',
        'auth' =>
          'Skrzynka Somfy odrzuciła token. Utwórz nowy w menu „Tryb dewelopera” w aplikacji TaHoma.',
        'unsupported' => 'To urządzenie Somfy nie obsługuje takiego polecenia.',
        _ =>
          'Skrzynka Somfy odpowiedziała nieoczekiwanie. Sprawdź adres i token.',
      };

  @override
  String toString() => 'SomfyException($code)';
}

/// Lokalne API TaHoma (tryb dewelopera): HTTPS na porcie 8443 z tokenem w nagłówku `Authorization`.
///
/// Skrzynka ma certyfikat własnego urzędu Overkiz, a pod adresem IP nazwa się nie zgadza,
/// więc klient akceptuje certyfikat tylko dla adresu skrzynki, z którą rozmawia.
class SomfyClient {
  SomfyClient(
      {http.Client Function(String host)? clientFor,
      this.timeout = const Duration(seconds: 5)})
      : _clientFor = clientFor ?? _pinnedClient;

  final http.Client Function(String host) _clientFor;
  final Duration timeout;
  final Map<String, http.Client> _clients = {};

  static const port = 8443;
  static const _base = '/enduser-mobile-web/1/enduserAPI';

  static http.Client _pinnedClient(String host) => IOClient(
      HttpClient()..badCertificateCallback = (cert, h, p) => h == host);

  http.Client _client(String host) =>
      _clients.putIfAbsent(host, () => _clientFor(host));

  /// `2001-1234-5678` -> `gateway-2001-1234-5678.local`; wszystko inne to nazwa hosta lub IP.
  static String hostFor(String input) {
    var value = input.trim().replaceFirst(RegExp(r'^https?://'), '');
    final slash = value.indexOf('/');
    if (slash >= 0) value = value.substring(0, slash);
    value = value.replaceFirst(RegExp(r':\d+$'), '');
    if (RegExp(r'^\d{4}-\d{4}-\d{4}$').hasMatch(value))
      return 'gateway-$value.local';
    return value;
  }

  Future<dynamic> _send(String method, SomfyGateway gw, String path,
      {Object? body}) async {
    final request = http.Request(method,
        Uri(scheme: 'https', host: gw.host, port: port, path: '$_base$path'))
      ..headers['authorization'] = 'Bearer ${gw.token}'
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);

    http.Response response;
    try {
      response = await http.Response.fromStream(
          await _client(gw.host).send(request).timeout(timeout));
    } on Exception {
      throw const SomfyException('network');
    }
    if (response.statusCode == 401 || response.statusCode == 403)
      throw const SomfyException('auth');
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw const SomfyException('invalid');
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw const SomfyException('invalid');
    }
  }

  /// Sprawdza token i zwraca skrzynkę (numer PIN pobrany z odpowiedzi).
  Future<SomfyGateway> connect(String input, String token) async {
    final host = hostFor(input);
    final token0 = token.trim();
    if (host.isEmpty || token0.isEmpty) throw const SomfyException('invalid');
    final probe = SomfyGateway(id: host, host: host, token: token0);
    final json = await _send('GET', probe, '/setup');
    var id = host;
    if (json is Map &&
        json['gateways'] is List &&
        (json['gateways'] as List).isNotEmpty) {
      final g = (json['gateways'] as List).first;
      if (g is Map && g['gatewayId'] is String) id = g['gatewayId'] as String;
    }
    return SomfyGateway(id: id, host: host, token: token0);
  }

  /// Urządzenia, które da się otworzyć i zamknąć (rolety, markizy, bramy).
  Future<List<SomfyCover>> covers(SomfyGateway gw) async {
    final json = await _send('GET', gw, '/setup/devices');
    if (json is! List) throw const SomfyException('invalid');
    final covers = <SomfyCover>[];
    for (final d in json) {
      if (d is! Map) continue;
      final commands = _commandNames(d['definition']);
      if (!commands.contains('open') || !commands.contains('close')) continue;
      final states = <String, Object?>{
        for (final s in (d['states'] as List?) ?? const [])
          if (s is Map && s['name'] is String) s['name'] as String: s['value'],
      };
      covers.add(SomfyCover(
        url: d['deviceURL'] as String,
        name: (d['label'] as String?)?.trim().isNotEmpty == true
            ? d['label'] as String
            : 'Roleta',
        available: d['available'] != false,
        closure: (states['core:ClosureState'] as num?)?.round(),
        openClosed: states['core:OpenClosedState'] as String?,
        canSetPosition: commands.contains('setClosure'),
        stopCommand: commands.contains('stop')
            ? 'stop'
            : (commands.contains('my') ? 'my' : null),
      ));
    }
    return covers;
  }

  static Set<String> _commandNames(Object? definition) {
    final raw = definition is Map ? definition['commands'] : null;
    return {
      if (raw is List)
        for (final c in raw)
          if (c is String)
            c
          else if (c is Map && c['commandName'] is String)
            c['commandName'] as String,
    };
  }

  /// `UP`, `DOWN`, `STOP` albo `NN%` (otwarcie w procentach, 100 = otwarta).
  Future<void> command(
      SomfyGateway gw, SomfyCover cover, String command) async {
    final percent = command.endsWith('%')
        ? int.tryParse(command.substring(0, command.length - 1))
        : null;
    final Map<String, Object> action;
    if (percent != null) {
      if (!cover.canSetPosition) throw const SomfyException('unsupported');
      // Somfy podaje zamknięcie, my otwarcie.
      action = {
        'name': 'setClosure',
        'parameters': [100 - percent.clamp(0, 100)]
      };
    } else {
      final name = switch (command) {
        'UP' => 'open',
        'DOWN' => 'close',
        'STOP' => cover.stopCommand,
        _ => null,
      };
      if (name == null) throw const SomfyException('unsupported');
      action = {'name': name};
    }
    await _send('POST', gw, '/exec/apply', body: {
      'label': 'NestIQ',
      'actions': [
        {
          'deviceURL': cover.url,
          'commands': [action]
        },
      ],
    });
  }
}
