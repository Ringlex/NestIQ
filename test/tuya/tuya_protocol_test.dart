import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/tuya/tuya_protocol.dart';

// Ramki w fixtures.json wygenerowała referencyjna biblioteka tinytuya
// (tool/tuya/fixtures.py), także te udające odpowiedzi urządzenia.

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List sequential(int n) => Uint8List.fromList(List.generate(n, (i) => i));

void main() {
  final fixtures =
      (jsonDecode(File('test/tuya/fixtures.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();

  for (final f in fixtures) {
    final version = f['version'] as String;
    final frames = (f['frames'] as Map).cast<String, String>();

    group('Tuya $version zgodne z tinytuya', () {
      late TuyaCodec codec;

      setUp(() {
        codec = TuyaCodec(
          deviceId: f['deviceId'] as String,
          localKey: f['key'] as String,
          version: version,
          clock: () => f['now'] as int,
          random: sequential,
        );
        if (codec.needsNegotiation) {
          expect(toHex(codec.negotiationStart()), frames['negStart'],
              reason: 'krok 1 negocjacji');
          final response = codec.parse(hex(frames['negResp']!));
          expect(toHex(codec.negotiationFinish(response)), frames['negFinish'],
              reason: 'krok 3');
        }
      });

      test('klucz sesji jest taki sam jak w tinytuya', () {
        expect(toHex(codec.sessionKey), f['sessionKey']);
      });

      test('polecenia są budowane bajt w bajt tak samo', () {
        expect(toHex(codec.buildControl({'1': true, '2': false})),
            frames['control']);
        expect(toHex(codec.buildQuery()), frames['query']);
        expect(toHex(codec.buildHeartbeat()), frames['heartbeat']);
      });

      test('odczytuje status wysłany przez urządzenie', () {
        final frame = codec.parse(hex(frames['status']!));
        expect(frame.cmd, TuyaCmd.status);
        expect(codec.decodeDps(frame), f['statusDps']);
      });

      test('odczytuje odpowiedź na zapytanie', () {
        final frame = codec.parse(hex(frames['queryResponse']!));
        expect(codec.decodeDps(frame), f['queryDps']);
      });

      test('potwierdzenie polecenia nie niesie punktów danych', () {
        final frame = codec.parse(hex(frames['controlAck']!));
        expect(frame.retcode, 0);
        expect(codec.decodeDps(frame), isNull);
      });

      test('uszkodzona ramka jest odrzucana', () {
        final bad = hex(frames['status']!);
        bad[bad.length ~/ 2] ^= 0xFF;
        expect(() => codec.parse(bad), throwsA(isA<TuyaProtocolException>()));
      });
    });
  }

  group('negocjacja klucza', () {
    test('zły klucz lokalny kończy się czytelnym błędem', () {
      final f = fixtures.firstWhere((x) => x['version'] == '3.4');
      final frames = (f['frames'] as Map).cast<String, String>();
      final codec = TuyaCodec(
        deviceId: f['deviceId'] as String,
        localKey: 'ZZZZZZZZZZZZZZZZ',
        version: '3.4',
        random: sequential,
      )..negotiationStart();

      expect(
        () => codec.negotiationFinish(codec.parse(hex(frames['negResp']!))),
        throwsA(isA<TuyaProtocolException>()),
      );
    });

    test('klucz lokalny musi mieć 16 znaków, a wersja być obsługiwana', () {
      expect(() => TuyaCodec(deviceId: 'x', localKey: 'krotki', version: '3.3'),
          throwsA(isA<TuyaProtocolException>()));
      expect(
          () => TuyaCodec(
              deviceId: 'x', localKey: '0123456789abcdef', version: '3.1'),
          throwsA(isA<TuyaProtocolException>()));
    });
  });

  group('ramkowanie strumienia', () {
    test('długość ramki wyznaczana z nagłówka', () {
      final f = fixtures.firstWhere((x) => x['version'] == '3.3');
      final frame = hex((f['frames'] as Map)['status'] as String);
      expect(peekFrameLength(frame), frame.length);
      expect(peekFrameLength(frame.sublist(0, 10)), isNull);
      expect(peekFrameLength(Uint8List.fromList([1, 2, 3, 4, 5])), -1);

      final f35 = fixtures.firstWhere((x) => x['version'] == '3.5');
      final frame35 = hex((f35['frames'] as Map)['status'] as String);
      expect(peekFrameLength(frame35), frame35.length);
    });
  });

  test('CRC32 zgadza się ze standardem', () {
    expect(crc32(utf8.encode('123456789')), 0xCBF43926);
  });
}
