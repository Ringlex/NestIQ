// Podgląd ruchu bramki Mobilus Cosmo GTW – tylko nasłuch, niczego nie steruje.
//
// Loguje się do bramki (żeby poznać klucze sesji), subskrybuje wszystkie
// tematy MQTT i wypisuje każdą wiadomość: kategorię, nadawcę i odszyfrowane
// ciało jako drzewo pól protobuf. Służy do poznania nieopisanych wiadomości,
// np. listy scen, którą pobiera aplikacja Mobilus.
//
// Użycie (komputer w tej samej sieci co bramka):
//   dart run tool/sniff_gateway.dart <IP bramki> <użytkownik> <hasło> [plik.log] [--ask=5,7,9]
// a następnie w aplikacji Mobilus na telefonie otwórz ekran scen.
// Ctrl+C kończy nasłuch.
//
// Każda sesja ma własne klucze, ale przychodzą one w LoginResponse
// zaszyfrowanym kluczem z hasła – narzędzie zapamiętuje je dla każdego
// klienta i odszyfrowuje także ruch aplikacji Mobilus.
//
// --ask wysyła po zalogowaniu prośby o podanych kategoriach z pustym ciałem
// (tak jak aplikacja Mobilus po starcie), np. żeby odczytać listy z bramki.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:nestiq/mobilus/codec.dart';
import 'package:nestiq/mobilus/proto.dart';
import 'package:typed_data/typed_buffers.dart';

const _known = {
  1: 'LoginRequest',
  2: 'LoginResponse',
  3: 'DevicesListRequest',
  4: 'DevicesListResponse',
  13: 'CallEvents',
  26: 'CurrentStateRequest',
  27: 'CurrentStateResponse',
};

Future<void> main(List<String> args) async {
  final ask = [
    for (final a in args.where((a) => a.startsWith('--ask=')))
      ...a.substring(6).split(',').map(int.parse),
  ];
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 3) {
    stderr.writeln('Użycie: dart run tool/sniff_gateway.dart <IP> <użytkownik> <hasło> '
        '[plik.log] [--ask=5,7,9]');
    exit(64);
  }
  final [host, login, password, ...rest] = positional;
  final log =
      File(rest.isNotEmpty ? rest.first : 'gateway_sniff.log').openWrite(mode: FileMode.append);
  void out(String line) {
    stdout.writeln(line);
    log.writeln(line);
  }

  final keys = KeyRing(password);
  // Klucze sesji każdego klienta (identyfikator → klucze z jego LoginResponse).
  final sessions = <String, KeyRing>{};
  final rnd = Random.secure();
  final clientId = List.generate(6, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  final mqtt = MqttServerClient.withPort('ws://$host/mqtt', clientId, 8884)
    ..useWebSocket = true
    ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
    ..setProtocolV311()
    ..keepAlivePeriod = 30
    ..logging(on: false)
    ..connectionMessage = MqttConnectMessage().withClientIdentifier(clientId).startClean();
  final wildcard = Completer<bool>();
  mqtt.onSubscribed = (t) {
    if (t == '#' && !wildcard.isCompleted) wildcard.complete(true);
  };
  mqtt.onSubscribeFail = (t) {
    out('! Bramka odrzuciła subskrypcję „$t”');
    if (t == '#' && !wildcard.isCompleted) wildcard.complete(false);
  };
  mqtt.onDisconnected = () => out('! Rozłączono');

  await mqtt.connect();
  out('# ${DateTime.now().toIso8601String()} połączono z $host, mój identyfikator $clientId');

  final loggedIn = Completer<void>();
  mqtt.updates!.listen((batch) {
    for (final m in batch) {
      final p = m.payload;
      if (p is! MqttPublishMessage) continue;
      final frame = Uint8List.fromList(p.payload.message);
      if (frame.length >= 17 && frame[4] == MobilusCodec.loginResponse) {
        final r = MobilusCodec.decode(frame, keys);
        if (r is LoginResponse && r.isAuthenticated) {
          if (m.topic == clientId) {
            keys.register(r);
            if (!loggedIn.isCompleted) loggedIn.complete();
          } else {
            sessions[m.topic] = KeyRing(password)..register(r);
          }
        }
      }
      out(_describe(m.topic, frame, keys, sessions, clientId));
    }
  });

  // „#” to wszystkie tematy; jeśli bramka tego nie pozwoli, zostają te znane.
  mqtt.subscribe('#', MqttQos.atMostOnce);
  final all = await wildcard.future.timeout(const Duration(seconds: 3), onTimeout: () => false);
  if (all) {
    out('# Subskrypcja „#” – widać ruch wszystkich klientów.');
  } else {
    out('! Bez „#” – widać tylko prośby klientów (module) i rozgłoszenia (clients), '
        'bez odpowiedzi bramki dla aplikacji Mobilus.');
    for (final t in [clientId, 'module', 'clients']) {
      mqtt.subscribe(t, MqttQos.atMostOnce);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  final frame = MobilusCodec.encode(LoginRequest(login: login, password: keys.userKey),
      clientId: clientId, keys: keys);
  mqtt.publishMessage('module', MqttQos.atMostOnce, Uint8Buffer()..addAll(frame));
  try {
    await loggedIn.future.timeout(const Duration(seconds: 10));
    out('# Zalogowano – teraz otwórz sceny w aplikacji Mobilus. Ctrl+C kończy.');
    for (final category in ask) {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final header = ByteData(17)
        ..setUint32(0, 13)
        ..setUint8(4, category)
        ..setUint32(5, ts)
        ..setUint8(15, 4);
      for (var i = 0; i < 6; i++) {
        header.setUint8(9 + i, int.parse(clientId.substring(i * 2, i * 2 + 2), radix: 16));
      }
      out('# Pytam bramkę: kategoria $category');
      mqtt.publishMessage(
          'module', MqttQos.atMostOnce, Uint8Buffer()..addAll(header.buffer.asUint8List()));
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  } on TimeoutException {
    out('! Logowanie nieudane – wiadomości będą widoczne, ale bez odszyfrowania.');
  }

  await ProcessSignal.sigint.watch().first;
  mqtt.disconnect();
  await log.close();
  exit(0);
}

String _describe(
    String topic, Uint8List frame, KeyRing keys, Map<String, KeyRing> sessions, String me) {
  final time = DateTime.now().toIso8601String().substring(11, 23);
  if (frame.length < 17) {
    return '$time [$topic] ${frame.length} B (nie ramka Mobilus): ${_hex(frame)}';
  }

  final header = ByteData.sublistView(frame, 0, 17);
  final category = header.getUint8(4);
  final ts = header.getUint32(5);
  final sender = _hex(frame.sublist(9, 15)).toUpperCase();
  final body = Uint8List.sublistView(frame, 17);
  final name = _known[category] ?? 'NIEZNANA';
  final who = sender == me ? 'ja' : sender;

  final buf = StringBuffer(
      '$time [$topic] kat=$category ($name) od=$who platforma=${frame[15]} kod=${frame[16]} '
      'ciało=${body.length} B');

  final other = sessions[sender];
  final candidates = <String, Uint8List?>{
    'jawne': null,
    'private_key': keys.privateKey,
    'public_key': keys.publicKey,
    'klucz hasła': keys.userKey,
    if (other != null) ...{
      'private_key klienta': other.privateKey,
      'public_key klienta': other.publicKey,
    },
  };
  for (final MapEntry(key: label, value: key) in candidates.entries) {
    if (label != 'jawne' && (key == null || key.isEmpty)) continue;
    final plain = key == null ? body : aesCfb(key, createIv(ts), body, encrypt: false);
    final tree = _tryParse(plain);
    if (tree != null) {
      buf.write(' – $label\n');
      // Skrót hasła (LoginRequest.2) i klucze sesji (LoginResponse.2, .3) to sekrety.
      final secret = switch (category) {
        MobilusCodec.loginRequest => const {2},
        MobilusCodec.loginResponse => const {2, 3},
        _ => const <int>{},
      };
      _dump(
          [for (final f in tree) secret.contains(f.number) ? _F(f.number, -1, 0) : f], buf, '    ');
      return buf.toString().trimRight();
    }
  }
  buf.write(' – nie udało się odczytać\n    hex: ${_hex(body)}');
  return buf.toString();
}

// ------------------------------------------------- ogólny parser protobuf

class _F {
  _F(this.number, this.wire, this.value);
  final int number;
  final int wire;
  final Object value; // int albo Uint8List
}

/// Zwraca pola tylko wtedy, gdy całe dane parsują się sensownie
/// (losowe bajty po złym kluczu prawie zawsze odpadają).
List<_F>? _tryParse(Uint8List data) {
  if (data.isEmpty) return const [];
  final fields = <_F>[];
  var pos = 0;
  int? varint() {
    var result = 0, shift = 0;
    while (pos < data.length && shift < 64) {
      final b = data[pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
    return null;
  }

  while (pos < data.length) {
    final key = varint();
    if (key == null) return null;
    final number = key >> 3, wire = key & 7;
    if (number < 1 || number > 64) return null;
    switch (wire) {
      case 0:
        final v = varint();
        if (v == null) return null;
        fields.add(_F(number, wire, v));
      case 2:
        final len = varint();
        if (len == null || len < 0 || pos + len > data.length) return null;
        fields.add(_F(number, wire, Uint8List.sublistView(data, pos, pos + len)));
        pos += len;
      case 1:
      case 5:
        final n = wire == 1 ? 8 : 4;
        if (pos + n > data.length) return null;
        fields.add(_F(number, wire, Uint8List.sublistView(data, pos, pos + n)));
        pos += n;
      default:
        return null;
    }
  }
  return fields;
}

void _dump(List<_F> fields, StringBuffer buf, String indent) {
  for (final f in fields) {
    final v = f.value;
    if (f.wire == -1) {
      buf.writeln('$indent${f.number}: (ukryte)');
      continue;
    }
    if (v is int) {
      buf.writeln('$indent${f.number}: $v');
      continue;
    }
    final bytes = v as Uint8List;
    final text = _asText(bytes);
    final nested = bytes.isEmpty ? null : _tryParse(bytes);
    if (text != null && (nested == null || bytes.length < 3)) {
      buf.writeln('$indent${f.number}: "$text"');
    } else if (nested != null && nested.isNotEmpty) {
      buf.writeln('$indent${f.number} {');
      _dump(nested, buf, '$indent  ');
      buf.writeln('$indent}');
    } else {
      buf.writeln('$indent${f.number}: hex ${_hex(bytes)}');
    }
  }
}

String? _asText(Uint8List bytes) {
  try {
    final s = utf8.decode(bytes);
    return s.runes.every((r) => r >= 0x20 || r == 0x0a || r == 0x09) ? s : null;
  } on FormatException {
    return null;
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
