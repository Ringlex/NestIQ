import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../devices/smart_device.dart';
import 'shelly_models.dart';

class ShellyException implements DeviceControlException {
  const ShellyException(this.code);

  /// `network`, `auth` albo `invalid`.
  final String code;

  @override
  String get message => switch (code) {
        'network' =>
          'Nie można połączyć się z urządzeniem Shelly. Sprawdź, czy jest włączone i w tej samej sieci.',
        'auth' =>
          'To urządzenie Shelly wymaga hasła. Wyłącz hasło w jego ustawieniach (Settings › Authentication).',
        _ =>
          'Urządzenie Shelly odpowiedziało nieoczekiwanie. Sprawdź adres i wersję urządzenia.',
      };

  @override
  String toString() => 'ShellyException($code)';
}

/// Lokalne API HTTP urządzeń Shelly: Gen1 (`/relay`, `/roller`) i Gen2+ (`/rpc/...`).
/// Bez haseł: urządzenie z włączonym uwierzytelnianiem zgłaszamy czytelnym błędem.
class ShellyClient {
  ShellyClient({http.Client? client, this.timeout = const Duration(seconds: 3)})
      : _http = client ?? http.Client();

  final http.Client _http;
  final Duration timeout;

  static String normalizeHost(String input) {
    var host = input.trim();
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    final slash = host.indexOf('/');
    if (slash >= 0) host = host.substring(0, slash);
    return host;
  }

  Future<dynamic> _get(String host, String path,
      [Map<String, String>? query]) async {
    http.Response response;
    try {
      response = await _http
          .get(Uri(
              scheme: 'http', host: host, path: path, queryParameters: query))
          .timeout(timeout);
    } on Exception {
      throw const ShellyException('network');
    }
    if (response.statusCode == 401) throw const ShellyException('auth');
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw const ShellyException('invalid');
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw const ShellyException('invalid');
    }
  }

  Future<Map<String, dynamic>> _getMap(String host, String path,
      [Map<String, String>? query]) async {
    final json = await _get(host, path, query);
    if (json is! Map<String, dynamic>) throw const ShellyException('invalid');
    return json;
  }

  /// Rozpoznaje urządzenie i jego kanały.
  Future<ShellyDevice> probe(String input) async {
    final host = normalizeHost(input);
    if (host.isEmpty) throw const ShellyException('invalid');
    final info = await _getMap(host, '/shelly');
    final gen = (info['gen'] as num?)?.toInt() ?? 1;
    if (info['auth'] == true || info['auth_en'] == true)
      throw const ShellyException('auth');
    final mac = (info['mac'] as String?)?.toUpperCase() ?? host;

    if (gen >= 2) {
      final status = await _getMap(host, '/rpc/Shelly.GetStatus');
      final components = <ShellyComponent>[];
      for (final key in status.keys) {
        final m = RegExp(r'^(switch|light|cover):(\d+)$').firstMatch(key);
        if (m == null) continue;
        components.add(ShellyComponent(
          switch (m.group(1)) {
            'cover' => ShellyKind.cover,
            'light' => ShellyKind.light,
            _ => ShellyKind.relay,
          },
          int.parse(m.group(2)!),
        ));
      }
      final model = (info['app'] ?? info['model'] ?? 'Shelly').toString();
      return ShellyDevice(
        id: mac,
        name: (info['name'] as String?)?.trim().isNotEmpty == true
            ? info['name'] as String
            : model,
        host: host,
        gen: gen,
        model: model,
        components: components,
      );
    }

    final settings = await _getMap(host, '/settings');
    final components = <ShellyComponent>[];
    final roller = settings['mode'] == 'roller';
    if (roller) {
      for (var i = 0; i < ((settings['rollers'] as List?)?.length ?? 0); i++) {
        components.add(ShellyComponent(ShellyKind.cover, i));
      }
    } else {
      for (var i = 0; i < ((settings['relays'] as List?)?.length ?? 0); i++) {
        components.add(ShellyComponent(ShellyKind.relay, i));
      }
    }
    for (var i = 0; i < ((settings['lights'] as List?)?.length ?? 0); i++) {
      components.add(ShellyComponent(ShellyKind.light, i));
    }
    final model = (info['type'] ?? 'Shelly').toString();
    final name = settings['name'];
    return ShellyDevice(
      id: mac,
      name: name is String && name.trim().isNotEmpty ? name : model,
      host: host,
      gen: 1,
      model: model,
      components: components,
    );
  }

  /// Stan wszystkich kanałów urządzenia, kluczem jest `ShellyComponent.key`.
  Future<Map<String, ShellyState>> status(ShellyDevice device) async {
    final host = device.host;
    if (device.gen >= 2) {
      final entries = await Future.wait([
        for (final c in device.components)
          () async {
            final method = switch (c.kind) {
              ShellyKind.cover => 'Cover.GetStatus',
              ShellyKind.light => 'Light.GetStatus',
              ShellyKind.relay => 'Switch.GetStatus',
            };
            final json = await _getMap(host, '/rpc/$method', {'id': '${c.id}'});
            if (c.kind == ShellyKind.cover) {
              final state = json['state'];
              return MapEntry(
                c.key,
                ShellyState(
                  position: (json['current_pos'] as num?)?.toInt(),
                  moving: state == 'opening' || state == 'closing',
                ),
              );
            }
            return MapEntry(c.key, ShellyState(on: json['output'] == true));
          }(),
      ]);
      return Map.fromEntries(entries);
    }

    final json = await _getMap(host, '/status');
    final out = <String, ShellyState>{};
    List list(String key) => (json[key] as List?) ?? const [];
    for (final c in device.components) {
      switch (c.kind) {
        case ShellyKind.relay:
          final items = list('relays');
          if (c.id < items.length)
            out[c.key] = ShellyState(on: (items[c.id] as Map)['ison'] == true);
        case ShellyKind.light:
          final items = list('lights');
          if (c.id < items.length)
            out[c.key] = ShellyState(on: (items[c.id] as Map)['ison'] == true);
        case ShellyKind.cover:
          final items = list('rollers');
          if (c.id < items.length) {
            final r = items[c.id] as Map;
            out[c.key] = ShellyState(
              position: (r['current_pos'] as num?)?.toInt(),
              // W Gen1 `state` open/close oznacza ruch w tym kierunku, `stop` – postój.
              moving: r['state'] == 'open' || r['state'] == 'close',
            );
          }
      }
    }
    return out;
  }

  Future<void> setOutput(
      ShellyDevice device, ShellyComponent c, bool on) async {
    if (device.gen >= 2) {
      final method = c.kind == ShellyKind.light ? 'Light.Set' : 'Switch.Set';
      await _get(device.host, '/rpc/$method', {'id': '${c.id}', 'on': '$on'});
    } else {
      final path =
          c.kind == ShellyKind.light ? '/light/${c.id}' : '/relay/${c.id}';
      await _get(device.host, path, {'turn': on ? 'on' : 'off'});
    }
  }

  /// `UP`, `DOWN`, `STOP` albo `NN%` (otwarcie w procentach, 100 = otwarta).
  Future<void> coverCommand(
      ShellyDevice device, ShellyComponent c, String command) async {
    final percent = command.endsWith('%')
        ? int.tryParse(command.substring(0, command.length - 1))
        : null;
    if (device.gen >= 2) {
      if (percent != null) {
        await _get(device.host, '/rpc/Cover.GoToPosition',
            {'id': '${c.id}', 'pos': '${percent.clamp(0, 100)}'});
        return;
      }
      final method = switch (command) {
        'UP' => 'Cover.Open',
        'DOWN' => 'Cover.Close',
        'STOP' => 'Cover.Stop',
        _ => throw const ShellyException('invalid'),
      };
      await _get(device.host, '/rpc/$method', {'id': '${c.id}'});
      return;
    }
    if (percent != null) {
      await _get(device.host, '/roller/${c.id}',
          {'go': 'to_pos', 'roller_pos': '${percent.clamp(0, 100)}'});
      return;
    }
    final go = switch (command) {
      'UP' => 'open',
      'DOWN' => 'close',
      'STOP' => 'stop',
      _ => throw const ShellyException('invalid'),
    };
    await _get(device.host, '/roller/${c.id}', {'go': go});
  }
}
