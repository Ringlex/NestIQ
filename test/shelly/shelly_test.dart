import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/screens/shelly_screen.dart';
import 'package:nestiq/shelly/shelly_client.dart';
import 'package:nestiq/shelly/shelly_controller.dart';
import 'package:nestiq/shelly/shelly_models.dart';
import 'package:nestiq/shelly/shelly_store.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/fake_server.dart';
import '../viessmann/fakes_faults.dart';

// Odpowiedzi zapisane na podstawie dokumentacji Shelly (Gen1 i Gen2+), nie z prawdziwego urządzenia.
const gen2Info = {
  'name': 'Salon',
  'id': 'shellyplus2pm-aabbccddeeff',
  'mac': 'AABBCCDDEEFF',
  'model': 'SNSW-102P16EU',
  'gen': 2,
  'ver': '1.0.8',
  'app': 'Plus2PM',
  'auth_en': false,
};

const gen1Info = {
  'type': 'SHSW-25',
  'mac': '112233445566',
  'auth': false,
  'fw': '20230913-112003/v1.14.0'
};

/// Atrapa urządzenia Shelly: mapa `ścieżka?zapytanie` → ciało; reszta to 404.
class FakeShelly {
  FakeShelly(this.routes);

  final Map<String, Object> routes;
  final List<String> log = [];
  bool offline = false;
  int? failWith;

  late final MockClient client = MockClient((request) async {
    final key = request.url.query.isEmpty
        ? request.url.path
        : '${request.url.path}?${request.url.query}';
    log.add(key);
    if (offline) throw http.ClientException('offline');
    if (failWith != null) return http.Response('{}', failWith!);
    final body = routes[key] ?? routes[request.url.path];
    if (body == null) return http.Response('{"error":"nope"}', 404);
    return http.Response(jsonEncode(body), 200);
  });
}

void main() {
  group('klient Shelly', () {
    test('Gen2: rozpoznaje roletę i nazwę', () async {
      final fake = FakeShelly({
        '/shelly': gen2Info,
        '/rpc/Shelly.GetStatus': {
          'sys': {},
          'wifi': {},
          'cover:0': {'id': 0, 'state': 'open', 'current_pos': 100}
        },
      });
      final device =
          await ShellyClient(client: fake.client).probe('http://192.168.1.50/');

      expect(device.id, 'AABBCCDDEEFF');
      expect(device.name, 'Salon');
      expect(device.gen, 2);
      expect(device.host, '192.168.1.50');
      expect(device.components.map((c) => c.key), ['cover:0']);
    });

    test('Gen2: kilka przekaźników i światło', () async {
      final fake = FakeShelly({
        '/shelly': {...gen2Info, 'name': null},
        '/rpc/Shelly.GetStatus': {
          'switch:0': {},
          'switch:1': {},
          'light:0': {},
          'wifi': {}
        },
      });
      final device =
          await ShellyClient(client: fake.client).probe('192.168.1.51');

      expect(device.name, 'Plus2PM', reason: 'bez nazwy używamy modelu');
      expect(device.components.map((c) => c.key),
          ['relay:0', 'relay:1', 'light:0']);
    });

    test('Gen1: tryb przekaźnikowy i rolety', () async {
      final relay = FakeShelly({
        '/shelly': gen1Info,
        '/settings': {
          'mode': 'relay',
          'relays': [{}, {}],
          'name': ''
        },
      });
      final a = await ShellyClient(client: relay.client).probe('192.168.1.60');
      expect(a.gen, 1);
      expect(a.name, 'SHSW-25');
      expect(a.components.map((c) => c.key), ['relay:0', 'relay:1']);

      final roller = FakeShelly({
        '/shelly': gen1Info,
        '/settings': {
          'mode': 'roller',
          'rollers': [{}],
          'relays': [{}, {}],
          'name': 'Okno'
        },
      });
      final b = await ShellyClient(client: roller.client).probe('192.168.1.61');
      expect(b.name, 'Okno');
      expect(b.components.map((c) => c.key), ['cover:0']);
    });

    test('hasło i brak sieci dają czytelne błędy', () async {
      await expectLater(
        ShellyClient(
                client: FakeShelly({
          '/shelly': {...gen2Info, 'auth_en': true}
        }).client)
            .probe('1.2.3.4'),
        throwsA(isA<ShellyException>().having((e) => e.code, 'code', 'auth')),
      );
      final unauthorized = FakeShelly({'/shelly': gen2Info})..failWith = 401;
      await expectLater(
        ShellyClient(client: unauthorized.client).probe('1.2.3.4'),
        throwsA(isA<ShellyException>().having((e) => e.code, 'code', 'auth')),
      );
      final offline = FakeShelly({})..offline = true;
      await expectLater(
        ShellyClient(client: offline.client).probe('1.2.3.4'),
        throwsA(
            isA<ShellyException>().having((e) => e.code, 'code', 'network')),
      );
      await expectLater(
        ShellyClient(client: FakeShelly({}).client).probe('  '),
        throwsA(
            isA<ShellyException>().having((e) => e.code, 'code', 'invalid')),
      );
    });

    test('Gen2: stan przekaźnika i rolety', () async {
      final fake = FakeShelly({
        '/rpc/Switch.GetStatus?id=0': {'id': 0, 'output': true},
        '/rpc/Cover.GetStatus?id=1': {
          'id': 1,
          'state': 'opening',
          'current_pos': 40
        },
      });
      const device = ShellyDevice(
        id: 'X',
        name: 'X',
        host: '1.1.1.1',
        gen: 2,
        model: 'm',
        components: [
          ShellyComponent(ShellyKind.relay, 0),
          ShellyComponent(ShellyKind.cover, 1)
        ],
      );
      final status = await ShellyClient(client: fake.client).status(device);

      expect(status['relay:0']!.on, isTrue);
      expect(status['cover:1']!.position, 40);
      expect(status['cover:1']!.moving, isTrue);
    });

    test('Gen1: stan z jednego /status', () async {
      final fake = FakeShelly({
        '/status': {
          'relays': [
            {'ison': true},
            {'ison': false},
          ],
          'rollers': [
            {'state': 'stop', 'current_pos': 100},
          ],
        },
      });
      const device = ShellyDevice(
        id: 'Y',
        name: 'Y',
        host: '1.1.1.2',
        gen: 1,
        model: 'm',
        components: [
          ShellyComponent(ShellyKind.relay, 1),
          ShellyComponent(ShellyKind.cover, 0)
        ],
      );
      final status = await ShellyClient(client: fake.client).status(device);

      expect(status['relay:1']!.on, isFalse);
      expect(status['cover:0']!.position, 100);
      expect(status['cover:0']!.moving, isFalse);
    });

    test('polecenia Gen2 trafiają w właściwe metody RPC', () async {
      final fake = FakeShelly({});
      const device = ShellyDevice(
          id: 'X',
          name: 'X',
          host: '1.1.1.1',
          gen: 2,
          model: 'm',
          components: []);
      final client = ShellyClient(client: fake.client);
      const cover = ShellyComponent(ShellyKind.cover, 0);

      await client
          .setOutput(device, const ShellyComponent(ShellyKind.relay, 1), true)
          .catchError((_) {});
      await client.coverCommand(device, cover, 'UP').catchError((_) {});
      await client.coverCommand(device, cover, 'DOWN').catchError((_) {});
      await client.coverCommand(device, cover, 'STOP').catchError((_) {});
      await client.coverCommand(device, cover, '40%').catchError((_) {});

      expect(fake.log, [
        '/rpc/Switch.Set?id=1&on=true',
        '/rpc/Cover.Open?id=0',
        '/rpc/Cover.Close?id=0',
        '/rpc/Cover.Stop?id=0',
        '/rpc/Cover.GoToPosition?id=0&pos=40',
      ]);
    });

    test('polecenia Gen1 używają /relay i /roller', () async {
      final fake = FakeShelly({});
      const device = ShellyDevice(
          id: 'Y',
          name: 'Y',
          host: '1.1.1.2',
          gen: 1,
          model: 'm',
          components: []);
      final client = ShellyClient(client: fake.client);
      const cover = ShellyComponent(ShellyKind.cover, 0);

      await client
          .setOutput(device, const ShellyComponent(ShellyKind.relay, 1), false)
          .catchError((_) {});
      await client.coverCommand(device, cover, 'UP').catchError((_) {});
      await client.coverCommand(device, cover, 'DOWN').catchError((_) {});
      await client.coverCommand(device, cover, 'STOP').catchError((_) {});
      await client.coverCommand(device, cover, '25%').catchError((_) {});

      expect(fake.log, [
        '/relay/1?turn=off',
        '/roller/0?go=open',
        '/roller/0?go=close',
        '/roller/0?go=stop',
        '/roller/0?go=to_pos&roller_pos=25',
      ]);
    });
  });

  group('kontroler Shelly', () {
    const relayDevice = ShellyDevice(
      id: 'AA',
      name: 'Kuchnia',
      host: '10.0.0.5',
      gen: 2,
      model: 'Plus2PM',
      components: [
        ShellyComponent(ShellyKind.relay, 0),
        ShellyComponent(ShellyKind.relay, 1)
      ],
    );
    const coverDevice = ShellyDevice(
      id: 'BB',
      name: 'Okno',
      host: '10.0.0.6',
      gen: 2,
      model: 'Plus2PM',
      components: [ShellyComponent(ShellyKind.cover, 0)],
    );

    late FakeShelly fake;
    late ShellyController shelly;
    var cover = {'id': 0, 'state': 'stopped', 'current_pos': 100};

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      cover = {'id': 0, 'state': 'stopped', 'current_pos': 100};
      // Lokalna kopia: opóźnione odświeżenia z poprzednich testów nie mogą pisać do nowej atrapy.
      final mine = fake = FakeShelly({});
      mine.routes
        ..['/rpc/Switch.GetStatus?id=0'] = {'output': false}
        ..['/rpc/Switch.GetStatus?id=1'] = {'output': true}
        ..['/rpc/Switch.Set'] = {'was_on': false}
        ..['/rpc/Cover.GoToPosition'] = {};
      shelly = ShellyController(
        client: ShellyClient(client: MockClient((r) async {
          // Roleta ma ruchomy stan, więc odpowiadamy z bieżącej zmiennej.
          if (r.url.path == '/rpc/Cover.GetStatus') {
            mine.log.add('${r.url.path}?${r.url.query}');
            return http.Response(jsonEncode(cover), 200);
          }
          return mine.client
              .send(http.Request(r.method, r.url))
              .then(http.Response.fromStream);
        })),
        store: ShellyStore(),
        pollInterval: const Duration(milliseconds: 40),
      );
      addTearDown(shelly.dispose);
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('dodane urządzenia dają światła z nazwami kanałów i kluczami do pokoi',
        () async {
      await shelly.add(relayDevice);
      await settle();

      final lights = shelly.lights;
      expect(lights.map((l) => l.name),
          ['Kuchnia · kanał 1', 'Kuchnia · kanał 2']);
      expect(lights.map((l) => l.on), [false, true]);
      expect(lights.first.key, RoomsController.shellyKey('AA', 'relay', 0));
      expect(lights.last.status, 'Włączone · lokalnie');
    });

    test('włączenie zmienia stan od razu i wysyła polecenie', () async {
      await shelly.add(relayDevice);
      await settle();

      final future = shelly.lights.first.set(true);
      expect(shelly.lights.first.on, isTrue,
          reason: 'optymistycznie, bez czekania na sieć');
      await future;

      expect(fake.log, contains('/rpc/Switch.Set?id=0&on=true'));
    });

    test('błąd sieci cofa stan, oznacza niedostępność i zgłasza wyjątek',
        () async {
      await shelly.add(relayDevice);
      await settle();
      fake.offline = true;

      await expectLater(
          shelly.lights.first.set(true), throwsA(isA<ShellyException>()));

      expect(shelly.lights.first.on, isFalse);
      expect(shelly.lights.first.available, isFalse);
      expect(shelly.lights.first.status, 'Niedostępne');
      expect(shelly.summary, contains('niedostępne: 1'));
    });

    test('roleta: pozycja, etykiety stanu i polecenia', () async {
      await shelly.add(coverDevice);
      await settle();

      var c = shelly.covers.single;
      expect(c.status, 'Otwarta');
      expect(c.position, 100);
      expect(c.supportsPosition, isTrue);

      cover = {'id': 0, 'state': 'stopped', 'current_pos': 35};
      await shelly.refresh();
      expect(shelly.covers.single.status, 'Otwarta w 35%');

      cover = {'id': 0, 'state': 'closing', 'current_pos': 20};
      await shelly.refresh();
      expect(shelly.covers.single.status, 'W ruchu');

      cover = {'id': 0, 'state': 'stopped', 'current_pos': 0};
      await shelly.refresh();
      expect(shelly.covers.single.status, 'Zamknięta');

      await shelly.covers.single.command('50%');
      expect(fake.log, contains('/rpc/Cover.GoToPosition?id=0&pos=50'));

      // Roleta bez kalibracji nie pokazuje suwaka.
      cover = {'id': 0, 'state': 'stopped', 'current_pos': 0};
      c = shelly.covers.single;
    });

    test('nieskalibrowana roleta ma tylko góra/stop/dół', () async {
      await shelly.add(coverDevice);
      cover = {'id': 0, 'state': 'stopped', 'current_pos': 0}..['current_pos'] =
          null as Object? ?? 0;
      cover = {'id': 0, 'state': 'stopped'};
      await shelly.refresh();

      final c = shelly.covers.single;
      expect(c.supportsPosition, isFalse);
      expect(c.status, contains('skalibruj'));
    });

    test(
        'ponowne dodanie tego samego urządzenia zmienia adres, ale zostawia nazwę',
        () async {
      await shelly.add(relayDevice);
      await shelly.rename('AA', 'Moja kuchnia');
      await shelly.add(relayDevice.copyWith(host: '10.0.0.99'));

      expect(shelly.devices, hasLength(1));
      expect(shelly.devices.single.host, '10.0.0.99');
      expect(shelly.devices.single.name, 'Moja kuchnia');
    });

    test('lista przeżywa restart, a usunięcie czyści stan', () async {
      await shelly.add(relayDevice);
      final again =
          ShellyController(client: shelly.client, store: ShellyStore());
      addTearDown(again.dispose);
      await again.load();
      expect(again.devices.single.id, 'AA');

      await shelly.remove('AA');
      expect(shelly.lights, isEmpty);
      expect(shelly.hasDevices, isFalse);
    });

    test('odpytywanie działa dopiero po start() i kończy się po stop()',
        () async {
      // Liczymy żądania w oknie czasu; w locie może jeszcze lecieć jedno odświeżenie.
      Future<int> requestsDuring(Duration d) async {
        final start = fake.log.length;
        await Future<void>.delayed(d);
        return fake.log.length - start;
      }

      await shelly.add(relayDevice);
      await settle();
      expect(await requestsDuring(const Duration(milliseconds: 200)), 0,
          reason: 'bez start() nic nie odpytuje');

      shelly.start();
      expect(await requestsDuring(const Duration(milliseconds: 200)),
          greaterThan(4));

      shelly.stop();
      await settle(); // dokańcza odświeżenie rozpoczęte przed stop()
      expect(await requestsDuring(const Duration(milliseconds: 200)), 0);
    });
  });

  group('na ekranie', () {
    late ShellyController shelly;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final fake = FakeShelly({
        '/shelly': gen2Info,
        '/rpc/Shelly.GetStatus': {'cover:0': {}, 'switch:0': {}},
        '/rpc/Cover.GetStatus': {
          'id': 0,
          'state': 'stopped',
          'current_pos': 60
        },
        '/rpc/Switch.GetStatus': {'id': 0, 'output': true},
      });
      shelly = ShellyController(
          client: ShellyClient(client: fake.client), store: ShellyStore());
      addTearDown(shelly.dispose);
    });

    Future<void> pumpHome(WidgetTester tester,
        {Size size = const Size(390, 1200), double scale = 1.0}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final account = AccountController(
        api: NestIqApi(
            baseUrl: 'http://test', client: FakeServer((_) => null).client),
        store: MemoryStore(),
      )
        ..active = Profile.fromJson(profileJson('a', 'Mama'))
        ..phase = AccountPhase.active;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data:
              MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: HomeScreen(
            account: account,
            session: SessionController(),
            rooms: RoomsController(),
            tuya: TuyaController(),
            viessmann: ViessmannController(),
            faults: testFaults(),
            sources: [shelly],
          ),
        ),
      ));
    }

    testWidgets(
        'światła i rolety Shelly pojawiają się na ekranie Dom bez bramki Mobilus',
        (tester) async {
      await tester.runAsync(() async {
        await shelly.add(ShellyDevice(
          id: 'AABBCCDDEEFF',
          name: 'Salon',
          host: '10.0.0.7',
          gen: 2,
          model: 'Plus2PM',
          components: const [
            ShellyComponent(ShellyKind.relay, 0),
            ShellyComponent(ShellyKind.cover, 0)
          ],
        ));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpHome(tester);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Salon'), findsWidgets);
      expect(find.text('Włączone · lokalnie'), findsOneWidget);
      expect(find.byTooltip('Świeci 1 z 1 świateł'), findsOneWidget);

      await tester.tap(find.byTooltip('Rolety').first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Otwarta w 60%'), findsOneWidget);
    });

    testWidgets('ekran Shelly: pusta lista, dodawanie po adresie IP i błąd',
        (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: ShellyScreen(shelly: shelly)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Nie dodano urządzeń Shelly'), findsOneWidget);

      await tester.tap(find.text('Dodaj urządzenie'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '10.0.0.7');
      await tester.tap(find.text('Szukaj'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      expect(find.text('Znaleziono urządzenie'), findsOneWidget);
      expect(find.textContaining('Roleta: 1'), findsOneWidget);
      await tester.tap(find.text('Dodaj'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      expect(shelly.devices.single.name, 'Salon');
      expect(find.text('Nie dodano urządzeń Shelly'), findsNothing);
    });

    testWidgets('bez overflow na 360×640 przy skali tekstu 2.0',
        (tester) async {
      await tester.runAsync(() async {
        await shelly.add(ShellyDevice(
          id: 'AABBCCDDEEFF',
          name: 'Salon z długą nazwą urządzenia',
          host: '10.0.0.7',
          gen: 2,
          model: 'Plus2PM',
          components: const [
            ShellyComponent(ShellyKind.relay, 0),
            ShellyComponent(ShellyKind.cover, 0)
          ],
        ));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpHome(tester, size: const Size(360, 640), scale: 2.0);
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byTooltip('Rolety').first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });
}
