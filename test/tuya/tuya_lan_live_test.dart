// Test na żywo: klient LAN Dart przeciwko atrapie urządzenia zbudowanej na tinytuya
// (tool/tuya/fake_device.py), osobno dla wersji 3.3, 3.4 i 3.5.
//   python3 -m venv .venv && .venv/bin/pip install tinytuya
//   flutter test test/tuya/tuya_lan_live_test.dart --dart-define=TUYA_PYTHON=$PWD/.venv/bin/python
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/tuya/tuya_lan_client.dart';

const python = String.fromEnvironment('TUYA_PYTHON');
const id = 'ebabcdef1234567890ab';
const key = '0123456789abcdef';

Future<Process> startDevice(String version, int port,
    {List<String> extra = const []}) async {
  final process = await Process.start(python, [
    'tool/tuya/fake_device.py',
    '--version',
    version,
    '--port',
    '$port',
    '--id',
    id,
    '--key',
    key,
    ...extra,
  ]);
  final ready = Completer<void>();
  process.stderr.transform(utf8.decoder).listen((text) {
    if (text.contains('nasłuchuje') && !ready.isCompleted) ready.complete();
    if (text.contains('błąd') || text.contains('zła') || text.contains('zły')) {
      // ignore: avoid_print
      print('[atrapa] $text');
    }
  });
  process.stdout.drain<void>();
  await ready.future.timeout(const Duration(seconds: 15));
  return process;
}

void main() {
  const skip = python == ''
      ? 'Podaj --dart-define=TUYA_PYTHON=.../python (patrz nagłówek)'
      : false;

  for (final entry in {'3.3': 16633, '3.4': 16634, '3.5': 16635}.entries) {
    final version = entry.key;
    final port = entry.value;

    group('klient LAN Tuya $version <-> atrapa na tinytuya', () {
      late Process device;
      late TuyaLanClient client;

      setUp(() async {
        device = await startDevice(version, port);
        client = TuyaLanClient(
          deviceId: id,
          localKey: key,
          version: version,
          host: '127.0.0.1',
          port: port,
          heartbeatInterval: const Duration(seconds: 1),
        );
        await client.connect();
      });

      tearDown(() async {
        await client.close();
        device.kill();
      });

      test('odczyt stanu, ustawienie, push i podtrzymanie połączenia',
          () async {
        expect(await client.queryStatus(), {'1': false, '2': true});

        final pushed = client.updates.firstWhere((u) => u['1'] == true);
        await client.setDps({'1': true});
        expect(await pushed.timeout(const Duration(seconds: 3)),
            containsPair('1', true));
        expect(await client.queryStatus(), {'1': true, '2': true});

        // Dłużej niż kilka okresów oddechu: połączenie nadal działa.
        await Future<void>.delayed(const Duration(milliseconds: 3200));
        expect(client.isConnected, isTrue);
        await client.setDps({'2': false});
        expect(await client.queryStatus(), {'1': true, '2': false});
      });

      test('kilka poleceń naraz nie miesza odpowiedzi', () async {
        await Future.wait([
          client.setDps({'1': true}),
          client.queryStatus(),
          client.setDps({'2': false}),
          client.queryStatus(),
        ]);
        expect(await client.queryStatus(), {'1': true, '2': false});
      });

      test('zamknięcie przez urządzenie kończy closed', () async {
        device.kill();
        await client.closed.timeout(const Duration(seconds: 5));
        expect(client.isConnected, isFalse);
      });
    }, skip: skip);
  }

  test('zły klucz lokalny: czytelny błąd zamiast zawieszenia (3.4)', () async {
    final device = await startDevice('3.4', 16636);
    final client = TuyaLanClient(
      deviceId: id,
      localKey: 'ZZZZZZZZZZZZZZZZ',
      version: '3.4',
      host: '127.0.0.1',
      port: 16636,
      requestTimeout: const Duration(seconds: 2),
    );
    try {
      await expectLater(client.connect(), throwsA(isA<TuyaLanException>()));
    } finally {
      await client.close();
      device.kill();
    }
  }, skip: skip);

  test('brak urządzenia pod adresem: błąd połączenia', () async {
    final client = TuyaLanClient(
      deviceId: id,
      localKey: key,
      version: '3.3',
      host: '127.0.0.1',
      port: 1,
      connectTimeout: const Duration(seconds: 1),
    );
    await expectLater(client.connect(), throwsA(isA<TuyaLanException>()));
  });
}
