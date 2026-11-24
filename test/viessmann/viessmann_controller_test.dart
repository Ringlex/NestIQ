import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/viessmann/viessmann_auth.dart';
import 'package:nestiq/viessmann/viessmann_client.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/viessmann/viessmann_models.dart';
import 'package:nestiq/viessmann/viessmann_store.dart';

import 'fakes.dart';
import 'fixtures.dart';

void main() {
  late MemoryViessmannStore store;
  late FakeViessmannApi api;

  ViessmannAuth fakeAuth({String? refresh = 'REFRESH'}) => ViessmannAuth(
        browser: (url, scheme) async =>
            'nestiq://viessmann?code=K&state=${Uri.parse(url).queryParameters['state']}',
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'access_token': 'AT',
              if (refresh != null) 'refresh_token': refresh,
              'expires_in': 3600
            }),
            200)),
      );

  ViessmannController build({
    ViessmannAuth? auth,
    Duration gap = Duration.zero,
    Duration poll = const Duration(milliseconds: 50),
  }) {
    store = MemoryViessmannStore();
    late ViessmannController controller;
    final c = ViessmannController(
      store: store,
      auth: auth ?? fakeAuth(),
      apiFactory: ({required token, required onCall}) =>
          api = FakeViessmannApi(onCall),
      pollInterval: poll,
      minRefreshGap: gap,
      settleDelay: Duration.zero,
      isInForeground: () => true,
    );
    controller = c;
    addTearDown(controller.dispose);
    return c;
  }

  const clientId = '1561f44a5fbce8acf0c3cea9334e5af1';

  Future<ViessmannController> connected({Duration gap = Duration.zero}) async {
    final c = build(gap: gap);
    await c.connect(clientId);
    return c;
  }

  group('połączenie', () {
    test('logowanie zapisuje sesję, znajduje piec i czyta stan', () async {
      final c = build();
      expect(c.isConfigured, isFalse);

      await c.connect(clientId);

      expect(c.isConfigured, isTrue);
      expect(c.state!.dhwTarget, 48);
      expect(store.saved.clientId, clientId);
      expect(store.saved.refreshToken, 'REFRESH');
      expect(store.saved.device!.deviceId, '0');
    });

    test('Client ID o złym kształcie jest odrzucany bez logowania', () async {
      final c = build();
      await expectLater(c.connect('krótki numer 1202737942'),
          throwsA(isA<ViessmannException>()));
      expect(c.isConfigured, isFalse);
    });

    test('po restarcie aplikacji sesja wraca z magazynu', () async {
      final first = await connected();
      final restored = ViessmannController(
        store: store,
        auth: fakeAuth(),
        apiFactory: ({required token, required onCall}) =>
            api = FakeViessmannApi(onCall),
      );
      addTearDown(restored.dispose);

      await restored.load();

      expect(restored.isConfigured, isTrue);
      expect(restored.clientId, first.clientId);
    });

    test('rozłączenie czyści dane', () async {
      final c = await connected();
      await c.disconnect();
      expect(c.isConfigured, isFalse);
      expect(c.state, isNull);
      expect(store.saved.refreshToken, isNull);
    });
  });

  group('odczyt i limit zapytań', () {
    test('odczyty następujące zaraz po sobie są pomijane, wymuszony przechodzi',
        () async {
      final c = await connected(gap: const Duration(minutes: 1));
      final before = api.featureCalls;

      await c.refresh();
      await c.refresh();
      expect(api.featureCalls, before,
          reason: 'poprzedni odczyt był przed chwilą');

      await c.refresh(force: true);
      expect(api.featureCalls, before + 1);
    });

    test('równoległe odczyty łączą się w jedno zapytanie', () async {
      final c = await connected();
      final before = api.featureCalls;
      await Future.wait([
        c.refresh(force: true),
        c.refresh(force: true),
        c.refresh(force: true)
      ]);
      expect(api.featureCalls, before + 1);
    });

    test('zapytania są liczone i zapisywane', () async {
      final c = await connected();
      expect(c.callsLast24h,
          greaterThanOrEqualTo(2)); // szukanie pieca + pierwszy odczyt
      expect(store.saved.calls, isNotEmpty);
    });

    test(
        'po wyczerpaniu budżetu odczyt się wstrzymuje, a użytkownik dostaje wyjaśnienie',
        () async {
      final c = await connected();
      final now = DateTime.now().millisecondsSinceEpoch;
      store.saved = StoredViessmann(
        clientId: clientId,
        refreshToken: 'R',
        device: testDevice,
        calls: List.filled(1400, now),
      );
      await c.load();
      final before = api.featureCalls;

      await c.refresh(force: true);

      expect(api.featureCalls, before);
      expect(c.error, contains('limit'));
    });

    test('stare zapytania spoza doby nie liczą się do limitu', () async {
      final c = build();
      final old = DateTime.now()
          .subtract(const Duration(hours: 25))
          .millisecondsSinceEpoch;
      store.saved = StoredViessmann(
          clientId: clientId,
          refreshToken: 'R',
          device: testDevice,
          calls: List.filled(1450, old));
      await c.load();
      expect(c.callsLast24h, 0);
    });

    test('błąd Viessmanna zostaje w stanie, a poprzedni odczyt jest zachowany',
        () async {
      final c = await connected();
      api.failWith = const ViessmannException('Viessmann nie odpowiada.');

      await c.refresh(force: true);

      expect(c.error, 'Viessmann nie odpowiada.');
      expect(c.state, isNotNull, reason: 'ostatni znany stan nie znika');
    });

    test(
        'odpytywanie działa, dopóki zakładka jest otwarta, i milknie po zamknięciu',
        () async {
      final c = await connected();
      final base = api.featureCalls;

      c.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      c.stopPolling();
      final polled = api.featureCalls;
      expect(polled, greaterThan(base + 1));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(api.featureCalls, polled);
    });

    test('powyżej budżetu odpytywania w tle odczyt już się nie dzieje',
        () async {
      final c = await connected();
      store.saved = StoredViessmann(
        clientId: clientId,
        refreshToken: 'R',
        device: testDevice,
        calls: List.filled(1250, DateTime.now().millisecondsSinceEpoch),
      );
      await c.load();
      final before = api.featureCalls;

      c.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      c.stopPolling();

      expect(api.featureCalls, before + 1,
          reason: 'tylko pierwszy odczyt po wejściu w zakładkę');
    });
  });

  group('sterowanie', () {
    test('temperatura c.w.u. jest wysyłana i potwierdzana odczytem', () async {
      final c = await connected();

      await c.setDhwTarget(52);

      expect(api.executed.single.$1, HeatingState.dhwTargetFeature);
      expect(api.executed.single.$2, 'setTargetTemperature');
      expect(api.executed.single.$3, {'temperature': 52});
      expect(c.state!.dhwTarget, 52);
    });

    test('temperatura poza zakresem pieca (30–60) nie jest wysyłana', () async {
      final c = await connected();
      await expectLater(c.setDhwTarget(75), throwsA(isA<ViessmannException>()));
      await expectLater(c.setDhwTarget(10), throwsA(isA<ViessmannException>()));
      expect(api.executed, isEmpty);
    });

    test(
        'nastawa obiegu: zakres to część wspólna polecenia (2–80) i poziomów obiegu (20–82)',
        () async {
      final c = await connected();
      final range = c.state!.circuitRange!;
      expect(range.min, 20);
      expect(range.max, 80);
      expect(range.step, 1);
    });

    test(
        'nastawa obiegu jest wysyłana poleceniem setTemperature i potwierdzana odczytem',
        () async {
      final c = await connected();

      await c.setCircuitTemperature(35);

      expect(api.executed.single.$1, HeatingState.programNormalFeature);
      expect(api.executed.single.$2, 'setTemperature');
      expect(api.executed.single.$3, {'targetTemperature': 35});
      expect(c.state!.programTemperature, 35);
    });

    test('nastawa obiegu poza zakresem nie jest wysyłana', () async {
      final c = await connected();
      await expectLater(
          c.setCircuitTemperature(85), throwsA(isA<ViessmannException>()));
      await expectLater(
          c.setCircuitTemperature(19), throwsA(isA<ViessmannException>()));
      expect(api.executed, isEmpty);
    });

    test('tryb c.w.u. i ogrzewania: tylko wartości, które piec dopuszcza',
        () async {
      final c = await connected();

      await c.setDhwMode('eco');
      await c.setHeatingMode('standby');

      expect(api.executed.map((e) => e.$3), [
        {'mode': 'eco'},
        {'mode': 'standby'},
      ]);
      expect(c.state!.heatingMode, 'standby');
      await expectLater(
          c.setDhwMode('turbo'), throwsA(isA<ViessmannException>()));
      await expectLater(
          c.setHeatingMode('cooling'), throwsA(isA<ViessmannException>()));
    });

    test('bez odczytu stanu sterowanie jest zablokowane (nie znamy zakresów)',
        () async {
      final c = build();
      await expectLater(c.setDhwTarget(50), throwsA(isA<ViessmannException>()));
    });

    test('tuż przed limitem polecenia są odrzucane', () async {
      final c = await connected();
      store.saved = StoredViessmann(
        clientId: clientId,
        refreshToken: 'R',
        device: testDevice,
        calls: List.filled(1448, DateTime.now().millisecondsSinceEpoch),
      );
      await c.load();
      await expectLater(c.setDhwTarget(50), throwsA(isA<ViessmannException>()));
      expect(api.executed, isEmpty);
    });
  });

  group('tokeny', () {
    test('wygasły token jest odnawiany raz, także gdy zapytań jest kilka naraz',
        () async {
      var refreshes = 0;
      var apiCalls = 0;
      final auth = ViessmannAuth(
        client: MockClient((r) async {
          refreshes++;
          return http.Response(
              jsonEncode(
                  {'access_token': 'NOWY$refreshes', 'expires_in': 3600}),
              200);
        }),
      );
      store = MemoryViessmannStore()
        ..saved = const StoredViessmann(
            clientId: clientId, refreshToken: 'R', device: testDevice);
      final c = ViessmannController(
        store: store,
        auth: auth,
        minRefreshGap: Duration.zero,
        apiFactory: ({required token, required onCall}) => ViessmannClient(
          token: token,
          onCall: onCall,
          client: MockClient((r) async {
            apiCalls++;
            expect(r.headers['Authorization'], 'Bearer NOWY1');
            return http.Response(jsonEncode({'data': vitodensFeatures()}), 200);
          }),
        ),
      );
      addTearDown(c.dispose);
      await c.load();

      await Future.wait([c.refresh(force: true), c.refresh(force: true)]);
      await c.refresh(force: true);

      expect(refreshes, 1, reason: 'jeden token wystarcza do końca godziny');
      expect(apiCalls, 2);
      expect(c.state!.dhwTarget, 48);
    });
  });
}
