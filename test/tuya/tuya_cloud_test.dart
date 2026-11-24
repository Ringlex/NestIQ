import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/tuya/tuya_cloud_client.dart';
import 'package:nestiq/tuya/tuya_models.dart';

// Podpisy w cloud_fixtures.json policzyła referencyjna biblioteka tinytuya
// (tool/tuya/cloud_fixtures.py).

void main() {
  final fixtures =
      jsonDecode(File('test/tuya/cloud_fixtures.json').readAsStringSync())
          as Map<String, dynamic>;
  final reference = (fixtures['requests'] as List).cast<Map<String, dynamic>>();
  final now = fixtures['now'] as int;
  final credentials = TuyaCloudCredentials(
    accessId: fixtures['clientId'] as String,
    accessSecret: fixtures['secret'] as String,
  );

  group('podpis żądań', () {
    for (final r in reference) {
      test('${r['method']} ${r['path']} zgodny z tinytuya', () {
        final signature = TuyaCloudClient.sign(
          clientId: credentials.accessId,
          secret: credentials.accessSecret,
          token: r['token'] as String?,
          timestamp: int.parse(r['t'] as String),
          method: r['method'] as String,
          pathWithQuery: r['path'] as String,
          body: r['body'] as String,
          signedHeaders: (r['signedHeaders'] as String).isEmpty
              ? const {}
              : {'Content-type': 'application/json'},
        );
        expect(signature, r['sign']);
      });
    }
  });

  group('klient chmury', () {
    late List<http.Request> seen;

    TuyaCloudClient clientWith(
        Map<String, dynamic> Function(http.Request) respond) {
      seen = [];
      return TuyaCloudClient(
        credentials: credentials,
        clockMillis: () => now,
        client: MockClient((request) async {
          seen.add(request);
          return http.Response(jsonEncode(respond(request)), 200);
        }),
      );
    }

    Map<String, dynamic> token() => {
          'success': true,
          'result': {'access_token': 'TOKEN123', 'expire_time': 7200},
        };

    test(
        'żądania niosą ten sam podpis co w tinytuya, w tym zapytanie z kilku stron',
        () async {
      final client = clientWith((r) {
        if (r.url.path == '/v1.0/token') return token();
        if (r.url.path == '/v1.0/iot-01/associated-users/devices') {
          final first = r.url.queryParameters['last_row_key'] == null;
          return {
            'success': true,
            'result': {
              'devices': <Object>[],
              'has_more': first,
              'last_row_key': first ? 'abc' : null
            },
          };
        }
        return {'success': true, 'result': {}};
      });

      await client.importDevices();

      expect(seen.map((r) => r.url.path).toList(), [
        '/v1.0/token',
        '/v1.0/iot-01/associated-users/devices',
        '/v1.0/iot-01/associated-users/devices'
      ]);
      expect(seen[0].headers['sign'], reference[0]['sign']);
      expect(seen[0].url.host, 'openapi.tuyaeu.com');
      expect(seen[2].url.query, 'last_row_key=abc&size=50');
      expect(seen[2].headers['sign'], reference[1]['sign']);
      expect(seen[2].headers['access_token'], 'TOKEN123');
      expect(seen[2].headers['client_id'], credentials.accessId);
      expect(seen[2].headers['sign_method'], 'HMAC-SHA256');
    });

    test(
        'import zwraca tylko urządzenia z przełącznikami i prawidłowym kluczem',
        () async {
      final client = clientWith((r) {
        switch (r.url.path) {
          case '/v1.0/token':
            return token();
          case '/v1.0/iot-01/associated-users/devices':
            return {
              'success': true,
              'result': {
                'devices': [
                  {
                    'id': 'dev1',
                    'name': 'Salon',
                    'local_key': '0123456789abcdef',
                    'category': 'kg'
                  },
                  {
                    'id': 'dev2',
                    'name': 'Czujnik',
                    'local_key': 'fedcba9876543210',
                    'category': 'wsdcg'
                  },
                  {
                    'id': 'dev3',
                    'name': 'Bez klucza',
                    'local_key': '',
                    'category': 'kg'
                  },
                ],
              },
            };
          case '/v1.1/devices/dev1/specifications':
            return {
              'success': true,
              'result': {
                'functions': [
                  {'code': 'switch_1', 'dp_id': 1, 'type': 'Boolean'},
                  {'code': 'switch_2', 'dp_id': 2, 'type': 'Boolean'},
                  {'code': 'switch_backlight', 'dp_id': 14, 'type': 'Boolean'},
                  {'code': 'countdown_1', 'dp_id': 9, 'type': 'Integer'},
                ],
                'status': [
                  {'code': 'switch_1', 'dp_id': 1, 'type': 'Boolean'},
                ],
              },
            };
          case '/v1.1/devices/dev2/specifications':
            return {
              'success': true,
              'result': {
                'functions': <Object>[],
                'status': [
                  {'code': 'va_temperature', 'dp_id': 1, 'type': 'Integer'},
                ],
              },
            };
        }
        return {'success': false, 'code': 404, 'msg': 'nie ma'};
      });

      final devices = await client.importDevices();

      // Czujnik (dev2) jest teraz importowany jako urządzenie bez przycisków; bez klucza (dev3) nadal odpada.
      expect(devices.map((d) => d.id), ['dev1', 'dev2']);
      final lamp = devices.first;
      expect(lamp.localKey, '0123456789abcdef');
      expect(lamp.channels.map((c) => (c.dpId, c.code, c.name)), [
        (1, 'switch_1', 'Przycisk 1'),
        (2, 'switch_2', 'Przycisk 2'),
      ]);
      expect(lamp.isSensor, isFalse);
      expect(devices.last.channels, isEmpty);
      expect(devices.last.isSensor, isTrue);
    });

    test('lampa ze switch_led ma dp 20, gdy chmura nie poda numeru', () {
      final channels = TuyaCloudClient.switchChannels({
        'functions': [
          {'code': 'switch_led', 'type': 'Boolean'},
          {'code': 'bright_value', 'type': 'Integer'},
        ],
      });
      expect(channels.single.dpId, 20);
    });

    test('polecenie przełączenia ma poprawne ciało i podpisane nagłówki',
        () async {
      final client = clientWith((r) => r.url.path == '/v1.0/token'
          ? token()
          : {'success': true, 'result': true});

      await client.setSwitch('dev1', 'switch_2', false);

      final post = seen.last;
      expect(post.method, 'POST');
      expect(post.url.path, '/v1.0/iot-03/devices/dev1/commands');
      expect(jsonDecode(post.body), {
        'commands': [
          {'code': 'switch_2', 'value': false},
        ],
      });
      expect(post.headers['Signature-Headers'], 'Content-type');
    });

    test('odczyt stanu zwraca tylko wartości logiczne', () async {
      final client = clientWith((r) => r.url.path == '/v1.0/token'
          ? token()
          : {
              'success': true,
              'result': [
                {'code': 'switch_1', 'value': true},
                {'code': 'switch_2', 'value': false},
                {'code': 'countdown_1', 'value': 0},
              ],
            });

      expect(await client.switchStates('dev1'),
          {'switch_1': true, 'switch_2': false});
    });

    test('wygasły token jest odnawiany i żądanie powtarzane raz', () async {
      var statusCalls = 0;
      var tokenCalls = 0;
      final client = clientWith((r) {
        if (r.url.path == '/v1.0/token') {
          tokenCalls++;
          return token();
        }
        statusCalls++;
        return statusCalls == 1
            ? {'success': false, 'code': 1010, 'msg': 'token invalid'}
            : {'success': true, 'result': <Object>[]};
      });

      await client.switchStates('dev1');

      expect(tokenCalls, 2);
      expect(statusCalls, 2);
    });

    test('wygasła i niewykupiona usługa API to dwa różne komunikaty z kodem',
        () async {
      Future<String> messageFor(int code) async {
        final client =
            clientWith((r) => {'success': false, 'code': code, 'msg': 'x'});
        try {
          await client.importDevices();
        } on TuyaCloudException catch (e) {
          return e.message;
        }
        return '';
      }

      final expired = await messageFor(28841002);
      final notSubscribed = await messageFor(28841105);
      expect(expired, allOf(contains('wygasła'), contains('28841002')));
      expect(notSubscribed,
          allOf(contains('nie ma wykupionej'), contains('28841105')));
    });

    test('błędy chmury mają czytelne komunikaty', () async {
      final client = clientWith(
          (r) => {'success': false, 'code': 1004, 'msg': 'sign invalid'});
      await expectLater(
        client.importDevices(),
        throwsA(isA<TuyaCloudException>()
            .having((e) => e.message, 'message', contains('Access Secret'))),
      );

      final offline = TuyaCloudClient(
        credentials: credentials,
        client:
            MockClient((_) async => throw const SocketException('brak sieci')),
      );
      await expectLater(
        offline.switchStates('x'),
        throwsA(isA<TuyaCloudException>()
            .having((e) => e.message, 'message', contains('Brak połączenia'))),
      );
    });
  });
}
