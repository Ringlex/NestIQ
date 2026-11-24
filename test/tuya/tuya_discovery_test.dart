import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/tuya/tuya_discovery.dart';

// Datagramy w udp_fixtures.json zbudowała biblioteka tinytuya (tool/tuya/udp_fixtures.py).

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

void main() {
  final f = jsonDecode(File('test/tuya/udp_fixtures.json').readAsStringSync())
      as Map<String, dynamic>;

  group('rozgłoszenia UDP', () {
    test('port 6667, urządzenia 3.3/3.4: ładunek szyfrowany kluczem UDP', () {
      final device = TuyaDiscovery.parseBroadcast(hex(f['ecb33'] as String))!;
      expect(device.id, f['id']);
      expect(device.ip, f['ip']);
      expect(device.version, '3.3');
    });

    test('port 6666, urządzenia 3.1: ładunek jawny', () {
      final device = TuyaDiscovery.parseBroadcast(hex(f['plain31'] as String))!;
      expect(device.id, f['id']);
      expect(device.version, '3.1');
    });

    test('urządzenia 3.5: ramka 6699 z kodem wyniku i bez niego', () {
      for (final key in ['gcm35', 'gcm35NoRetcode']) {
        final device = TuyaDiscovery.parseBroadcast(hex(f[key] as String))!;
        expect(device.id, f['id'], reason: key);
        expect(device.ip, f['ip'], reason: key);
        expect(device.version, '3.5', reason: key);
      }
    });

    test('śmieci i uszkodzone datagramy są ignorowane', () {
      expect(
          TuyaDiscovery.parseBroadcast(Uint8List.fromList([1, 2, 3])), isNull);
      expect(TuyaDiscovery.parseBroadcast(Uint8List(40)), isNull);
      final bad = hex(f['gcm35'] as String);
      bad[bad.length ~/ 2] ^= 0xFF;
      expect(TuyaDiscovery.parseBroadcast(bad), isNull);
    });

    test('zapytanie na port 7000 jest identyczne jak w tinytuya', () {
      final iv = Uint8List.fromList(List.generate(12, (i) => i));
      final request =
          TuyaDiscovery.buildRequest(f['requestIp'] as String, iv: iv);
      expect(request.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          f['request']);
    });
  });
}
