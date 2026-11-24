import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/viessmann/viessmann_auth.dart';
import 'package:nestiq/viessmann/viessmann_client.dart';
import 'package:nestiq/viessmann/viessmann_models.dart';

import 'fixtures.dart';

void main() {
  group('stan pieca z odpowiedzi API', () {
    final state = HeatingState.parse(vitodensFeatures());

    test('ciepła woda', () {
      expect(state.dhwCurrent, 49.6);
      expect(state.dhwTarget, 48);
      expect(state.dhwMode, 'comfort');
      expect(state.dhwComfort, isTrue);
    });

    test('kocioł, palnik i ogrzewanie', () {
      expect(state.supplyTemperature, 50.7);
      expect(state.boilerTemperature, 20);
      expect(state.burnerActive, isFalse);
      expect(state.modulation, 0);
      expect(state.burnerHours, 700);
      expect(state.burnerStarts, 21719);
      expect(state.heatingMode, 'heating');
      expect(state.activeProgram, 'normalEnergySaving');
      expect(state.programTemperature, 31);
      expect(state.malfunction, isFalse);
    });

    test('zakresy i dozwolone wartości pochodzą z poleceń pieca', () {
      expect(state.dhwRange!.min, 30);
      expect(state.dhwRange!.max, 60);
      expect(state.dhwRange!.step, 1);
      expect(state.dhwModes, ['comfort', 'eco', 'off']);
      expect(state.heatingModes, ['heating', 'standby']);
    });

    test('komunikaty statusowe i zużycie', () {
      expect(state.messages.map((m) => m.code), ['S.6', 'S.1']);
      expect(state.messages.first.time, isNotNull);
      expect(state.gasDhw!.today, 0.4);
      expect(state.gasDhw!.year, 238.7);
      expect(state.gasDhw!.unit, 'cubicMeter');
      expect(state.heatHeating!.month, 87);
      expect(state.heatHeating!.unit, 'kilowattHour');
    });

    test('funkcje bez wartości (brak czujników) nie psują odczytu', () {
      expect(
          state.features['heating.sensors.temperature.outside']!
              .number('value'),
          isNull);
      expect(
          state.features
              .containsKey('heating.circuits.0.sensors.temperature.room'),
          isTrue);
    });

    test('pusta odpowiedź daje stan bez wartości, a nie wyjątek', () {
      final empty = HeatingState.parse(const []);
      expect(empty.dhwTarget, isNull);
      expect(empty.dhwRange, isNull);
      expect(empty.dhwModes, isNotEmpty,
          reason: 'domyślne tryby, gdy piec ich nie podał');
      expect(empty.messages, isEmpty);
    });
  });

  group('logowanie OAuth2 + PKCE', () {
    test('wyzwanie PKCE zgadza się z wektorem z RFC 7636', () {
      expect(
          ViessmannAuth.codeChallenge(
              'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
          'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('adres logowania ma wszystkie wymagane parametry', () {
      final q = ViessmannAuth.authorizeUri(
              clientId: 'CID', challenge: 'CH', state: 'ST')
          .queryParameters;
      expect(q['client_id'], 'CID');
      expect(q['redirect_uri'], 'nestiq://viessmann');
      expect(q['response_type'], 'code');
      expect(q['code_challenge_method'], 'S256');
      expect(q['scope'], contains('IoT User'));
      expect(q['scope'], contains('offline_access'));
    });

    test('kod wymieniany jest na token razem z tym samym verifierem', () async {
      late Map<String, String> form;
      String? challenge;
      final auth = ViessmannAuth(
        browser: (url, scheme) async {
          final q = Uri.parse(url).queryParameters;
          challenge = q['code_challenge'];
          expect(scheme, 'nestiq');
          return 'nestiq://viessmann?code=KOD123&state=${q['state']}';
        },
        client: MockClient((r) async {
          form = r.bodyFields;
          return http.Response(
              jsonEncode({
                'access_token': 'AT',
                'refresh_token': 'RT',
                'expires_in': 3600
              }),
              200);
        }),
      );

      final tokens = await auth.login('CID');

      expect(tokens.accessToken, 'AT');
      expect(tokens.refreshToken, 'RT');
      expect(tokens.isExpired, isFalse);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'KOD123');
      expect(form['client_id'], 'CID');
      expect(form['redirect_uri'], 'nestiq://viessmann');
      expect(ViessmannAuth.codeChallenge(form['code_verifier']!), challenge);
    });

    test('podmieniony parametr state kończy logowanie błędem', () async {
      final auth = ViessmannAuth(
        browser: (url, scheme) async => 'nestiq://viessmann?code=X&state=OBCY',
        client: MockClient(
            (_) async => throw StateError('nie powinno dojść do tokenu')),
      );
      await expectLater(auth.login('CID'), throwsA(isA<ViessmannException>()));
    });

    test('odmowa i przerwanie logowania mają czytelne komunikaty', () async {
      final denied = ViessmannAuth(
        browser: (url, scheme) async =>
            'nestiq://viessmann?error=access_denied&error_description=Brak%20zgody',
        client: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
          denied.login('CID'),
          throwsA(isA<ViessmannException>()
              .having((e) => e.message, 'message', contains('Brak zgody'))));

      final closed = ViessmannAuth(
        browser: (url, scheme) async =>
            throw PlatformException(code: 'CANCELED'),
        client: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
          closed.login('CID'),
          throwsA(isA<ViessmannException>()
              .having((e) => e.message, 'message', contains('przerwane'))));
    });

    test(
        'niezarejestrowany adres przekierowania jest wykrywany przed otwarciem przeglądarki',
        () async {
      var browserOpened = false;
      final auth = ViessmannAuth(
        browser: (url, scheme) async {
          browserOpened = true;
          return '';
        },
        client: MockClient((r) async {
          expect(r.url.path, endsWith('/authorize'));
          return http.Response(
              jsonEncode({
                'error': 'invalid_request',
                'error_description': 'Invalid redirection URI.'
              }),
              400);
        }),
      );

      await expectLater(
        auth.login('CID'),
        throwsA(isA<ViessmannException>().having((e) => e.message, 'message',
            allOf(contains('nestiq://viessmann'), contains('Redirect URIs')))),
      );
      expect(browserOpened, isFalse);
    });

    test('inny błąd odrzucenia klienta (zły Client ID) jest opisany', () async {
      final auth = ViessmannAuth(
        browser: (url, scheme) async => '',
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'error': 'invalid_client',
              'error_description': 'Unknown client'
            }),
            400)),
      );
      await expectLater(
        auth.login('CID'),
        throwsA(isA<ViessmannException>()
            .having((e) => e.message, 'message', contains('Unknown client'))),
      );
    });

    test('brak sieci przy sprawdzaniu nie blokuje logowania', () async {
      var calls = 0;
      final auth = ViessmannAuth(
        browser: (url, scheme) async =>
            'nestiq://viessmann?code=K&state=${Uri.parse(url).queryParameters['state']}',
        client: MockClient((r) async {
          calls++;
          if (r.url.path.endsWith('/authorize')) {
            throw http.ClientException('brak sieci');
          }
          return http.Response(
              jsonEncode({'access_token': 'AT', 'expires_in': 3600}), 200);
        }),
      );
      final tokens = await auth.login('CID');
      expect(tokens.accessToken, 'AT');
      expect(calls, 2);
    });

    test('inny błąd wtyczki przeglądarki pokazuje jego kod', () async {
      final auth = ViessmannAuth(
        browser: (url, scheme) async => throw PlatformException(
            code: 'channel-error', message: 'Brak aktywności'),
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(
        auth.login('CID'),
        throwsA(isA<ViessmannException>().having((e) => e.message, 'message',
            allOf(contains('channel-error'), contains('Brak aktywności')))),
      );
    });

    test('odświeżenie zachowuje stary token, gdy serwer nie wyda nowego',
        () async {
      final auth = ViessmannAuth(
        client: MockClient((r) async {
          expect(r.bodyFields['grant_type'], 'refresh_token');
          expect(r.bodyFields['refresh_token'], 'STARY');
          return http.Response(
              jsonEncode({'access_token': 'NOWY', 'expires_in': 3600}), 200);
        }),
      );
      final tokens = await auth.refresh('CID', 'STARY');
      expect(tokens.accessToken, 'NOWY');
      expect(tokens.refreshToken, 'STARY');
    });

    test('odrzucony token odświeżający wymaga ponownego logowania', () async {
      final auth = ViessmannAuth(
        client: MockClient((_) async =>
            http.Response(jsonEncode({'error': 'invalid_grant'}), 400)),
      );
      await expectLater(
        auth.refresh('CID', 'MARTWY'),
        throwsA(isA<ViessmannException>()
            .having((e) => e.needsLogin, 'needsLogin', isTrue)),
      );
    });
  });

  group('klient API', () {
    late List<http.Request> seen;
    late int calls;

    ViessmannClient clientWith(http.Response Function(http.Request) respond) {
      seen = [];
      calls = 0;
      return ViessmannClient(
        token: () async => 'TOKEN',
        onCall: () => calls++,
        client: MockClient((r) async {
          seen.add(r);
          return respond(r);
        }),
      );
    }

    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status);

    test('znajduje piec wśród urządzeń instalacji, pomijając bramę', () async {
      final client = clientWith((_) => json(installations()));
      final ref = await client.findHeatingDevice();
      expect(ref.deviceId, '0');
      expect(ref.gatewaySerial, '7000000051');
      expect(ref.installationId, '3300000006');
      expect(ref.modelId, 'E3_Vitodens_050_08');
      expect(seen.single.headers['Authorization'], 'Bearer TOKEN');
      expect(seen.single.url.path, '/iot/v2/equipment/installations');
    });

    test('konto bez pieca daje czytelny błąd', () async {
      final client = clientWith((_) => json({'data': <Object>[]}));
      await expectLater(
          client.findHeatingDevice(), throwsA(isA<ViessmannException>()));
    });

    test('odczyt funkcji to jedno zapytanie', () async {
      final client = clientWith((_) => json({'data': vitodensFeatures()}));
      final data = await client.features(testDevice);
      expect(data.length, vitodensFeatures().length);
      expect(calls, 1);
      expect(seen.single.url.path,
          '/iot/v2/features/installations/I/gateways/G/devices/0/features');
    });

    test('polecenie idzie na adres podany przez API, z ciałem JSON', () async {
      final client = clientWith((_) => json({
            'data': {'success': true}
          }));
      final command = HeatingState.parse(vitodensFeatures())
          .command(HeatingState.dhwTargetFeature, 'setTargetTemperature')!;

      await client.execute(testDevice, command, {'temperature': 50});

      expect(seen.single.method, 'POST');
      expect(
          seen.single.url.path,
          endsWith(
              '/features/heating.dhw.temperature.main/commands/setTargetTemperature'));
      expect(jsonDecode(seen.single.body), {'temperature': 50});
      expect(seen.single.headers['Content-Type'], contains('application/json'));
    });

    test(
        'token nie wychodzi poza API Viessmanna, nawet jeśli polecenie wskazuje obcy adres',
        () async {
      final client = clientWith((_) => json({}));
      const evil = FeatureCommand(
          name: 'x', uri: 'https://obcy.example.com/steal', executable: true);
      await expectLater(client.execute(testDevice, evil, {}),
          throwsA(isA<ViessmannException>()));
      expect(seen, isEmpty);
    });

    test('polecenie niewykonalne i odrzucone przez piec rzucają wyjątek',
        () async {
      final client = clientWith((_) => json({
            'data': {'success': false, 'reason': 'DEVICE_COMMUNICATION_ERROR'}
          }));
      const locked =
          FeatureCommand(name: 'x', uri: '$viessmannApi/a', executable: false);
      await expectLater(client.execute(testDevice, locked, {}),
          throwsA(isA<ViessmannException>()));
      const ok =
          FeatureCommand(name: 'x', uri: '$viessmannApi/a', executable: true);
      await expectLater(
        client.execute(testDevice, ok, {}),
        throwsA(isA<ViessmannException>().having((e) => e.message, 'message',
            contains('DEVICE_COMMUNICATION_ERROR'))),
      );
    });

    test('limit zapytań i wygasła sesja są rozpoznawane', () async {
      final limited = clientWith((_) => json({'message': 'limit'}, 429));
      await expectLater(
        limited.features(testDevice),
        throwsA(isA<ViessmannException>()
            .having((e) => e.isRateLimited, 'isRateLimited', isTrue)),
      );
      final expired = clientWith((_) => json({}, 401));
      await expectLater(
        expired.features(testDevice),
        throwsA(isA<ViessmannException>()
            .having((e) => e.needsLogin, 'needsLogin', isTrue)),
      );
    });
  });
}
