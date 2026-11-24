import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/hue/hue_client.dart';
import 'package:nestiq/hue/hue_controller.dart';
import 'package:nestiq/hue/hue_models.dart';
import 'package:nestiq/hue/hue_store.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/screens/hue_screen.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/fake_server.dart';
import '../viessmann/fakes_faults.dart';

// Odpowiedzi zapisane według opisu API Hue v2 (CLIP), nie z prawdziwego mostka.
Map<String, dynamic> light(String id, String name,
        {bool on = false, num? brightness, String owner = 'dev-1'}) =>
    {
      'id': id,
      'owner': {'rid': owner, 'rtype': 'device'},
      'metadata': {'name': name, 'archetype': 'sultan_bulb'},
      'on': {'on': on},
      if (brightness != null) 'dimming': {'brightness': brightness},
    };

class MemoryHueStore implements HueStore {
  HueBridge? saved;

  @override
  Future<HueBridge?> load() async => saved;

  @override
  Future<void> save(HueBridge bridge) async => saved = bridge;

  @override
  Future<void> clear() async => saved = null;
}

/// Atrapa mostka: stan lamp w pamięci, żądania w [log] jako `METODA ścieżka`.
class FakeBridge {
  final List<String> log = [];
  final List<http.Request> requests = [];
  bool linkPressed = false;
  bool offline = false;
  int? failWith;
  List<Map<String, dynamic>> lights = [
    light('L1', 'Salon', on: true, brightness: 80, owner: 'dev-1'),
    light('L2', 'Kinkiet', on: false, brightness: 30, owner: 'dev-2'),
    light('L3', 'Girlanda', on: false, owner: 'dev-3'),
  ];
  List<Map<String, dynamic>> connectivity = [
    {
      'owner': {'rid': 'dev-1'},
      'status': 'connected'
    },
    {
      'owner': {'rid': 'dev-2'},
      'status': 'connectivity_issue'
    },
    {
      'owner': {'rid': 'dev-3'},
      'status': 'connected'
    },
  ];

  late final MockClient client = MockClient((request) async {
    log.add('${request.method} ${request.url.path}');
    requests.add(request);
    if (offline) throw http.ClientException('offline');
    if (failWith != null) return http.Response('{}', failWith!);
    final path = request.url.path;
    if (request.method == 'POST' && path == '/api') {
      return http.Response(
        jsonEncode(linkPressed
            ? [
                {
                  'success': {'username': 'KEY123', 'clientkey': 'CK'}
                }
              ]
            : [
                {
                  'error': {
                    'type': 101,
                    'address': '',
                    'description': 'link button not pressed'
                  }
                }
              ]),
        200,
      );
    }
    if (path == '/clip/v2/resource/bridge') {
      return http.Response(
          jsonEncode({
            'errors': [],
            'data': [
              {'bridge_id': 'BRIDGE01'}
            ]
          }),
          200);
    }
    if (path == '/clip/v2/resource/light') {
      return http.Response(jsonEncode({'errors': [], 'data': lights}), 200);
    }
    if (path == '/clip/v2/resource/zigbee_connectivity') {
      return http.Response(
          jsonEncode({'errors': [], 'data': connectivity}), 200);
    }
    if (request.method == 'PUT' &&
        path.startsWith('/clip/v2/resource/light/')) {
      final id = path.split('/').last;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      lights = [
        for (final l in lights)
          if (l['id'] == id)
            {
              ...l,
              if (body['on'] != null) 'on': body['on'],
              if (body['dimming'] != null) 'dimming': body['dimming'],
            }
          else
            l,
      ];
      return http.Response(
          jsonEncode({
            'errors': [],
            'data': [
              {'rid': id}
            ]
          }),
          200);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  late FakeBridge bridge;
  late HueClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = FakeBridge();
    client = HueClient(
        clientFor: (_) => bridge.client, discoveryClient: bridge.client);
  });

  group('klient Hue', () {
    test(
        'parowanie: bez przycisku czytelny błąd, z przyciskiem klucz i id mostka',
        () async {
      await expectLater(
          client.pair('192.168.1.2'),
          throwsA(isA<HueException>()
              .having((e) => e.code, 'code', 'link_button')));

      bridge.linkPressed = true;
      final paired = await client.pair('https://192.168.1.2/');

      expect(paired.key, 'KEY123');
      expect(paired.id, 'BRIDGE01');
      expect(paired.host, '192.168.1.2');
      final post = bridge.requests.firstWhere((r) => r.method == 'POST');
      expect(post.url.scheme, 'https');
      expect(jsonDecode(post.body)['devicetype'], startsWith('nestiq#'));
    });

    test('lampki: nazwa, stan, jasność i łączność', () async {
      const b = HueBridge(id: 'B', host: '1.1.1.1', key: 'K');
      final lights = await client.lights(b);

      expect(lights.map((l) => l.name), ['Salon', 'Kinkiet', 'Girlanda']);
      expect(lights.map((l) => l.on), [true, false, false]);
      expect(lights.map((l) => l.brightness), [80, 30, null]);
      expect(lights.map((l) => l.reachable), [true, false, true]);
      expect(bridge.requests.first.headers['hue-application-key'], 'K');
    });

    test('brak danych o łączności nie psuje listy lamp', () async {
      bridge.connectivity = [];
      const b = HueBridge(id: 'B', host: '1.1.1.1', key: 'K');
      final lights = await client.lights(b);
      expect(lights.every((l) => l.reachable), isTrue);
    });

    test('polecenia: włączenie i jasność wysyłają właściwe ciała', () async {
      const b = HueBridge(id: 'B', host: '1.1.1.1', key: 'K');
      await client.setOn(b, 'L2', true);
      await client.setBrightness(b, 'L2', 55);

      final puts = bridge.requests.where((r) => r.method == 'PUT').toList();
      expect(puts.first.url.path, '/clip/v2/resource/light/L2');
      expect(jsonDecode(puts.first.body), {
        'on': {'on': true}
      });
      expect(jsonDecode(puts.last.body), {
        'on': {'on': true},
        'dimming': {'brightness': 55}
      });
    });

    test('błędy: klucz odrzucony, brak sieci, zły adres', () async {
      const b = HueBridge(id: 'B', host: '1.1.1.1', key: 'K');
      bridge.failWith = 403;
      await expectLater(client.lights(b),
          throwsA(isA<HueException>().having((e) => e.code, 'code', 'auth')));
      bridge.failWith = null;
      bridge.offline = true;
      await expectLater(
          client.lights(b),
          throwsA(
              isA<HueException>().having((e) => e.code, 'code', 'network')));
      await expectLater(
          client.pair('  '),
          throwsA(
              isA<HueException>().having((e) => e.code, 'code', 'invalid')));
    });

    test('wykrywanie: lista mostków i pusta lista przy błędzie', () async {
      final discovery = MockClient((r) async => http.Response(
          jsonEncode([
            {'id': 'abc', 'internalipaddress': '192.168.1.9', 'port': 443}
          ]),
          200));
      final found = await HueClient(discoveryClient: discovery).discover();
      expect(found.single.host, '192.168.1.9');

      final broken =
          MockClient((r) async => throw http.ClientException('no internet'));
      expect(await HueClient(discoveryClient: broken).discover(), isEmpty);
    });
  });

  group('kontroler Hue', () {
    late MemoryHueStore store;
    late HueController hue;
    const paired = HueBridge(id: 'BRIDGE01', host: '10.0.0.2', key: 'K');

    setUp(() {
      store = MemoryHueStore();
      hue = HueController(
          client: client,
          store: store,
          pollInterval: const Duration(milliseconds: 40));
      addTearDown(hue.dispose);
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('po połączeniu są lampy z kluczami do pokoi i statusami', () async {
      await hue.connect(paired);
      await settle();

      final lights = hue.lights;
      expect(lights.map((l) => l.name), ['Salon', 'Kinkiet', 'Girlanda']);
      expect(lights.first.key, RoomsController.hueKey('BRIDGE01', 'L1'));
      expect(lights.first.status, 'Włączone · 80% · Hue');
      expect(lights[1].available, isFalse);
      expect(lights[1].status, 'Lampa niedostępna');
      expect(lights[2].setBrightness, isNull, reason: 'lampa bez ściemniania');
      expect(store.saved?.key, 'K');
    });

    test('włączenie i jasność zmieniają stan od razu', () async {
      await hue.connect(paired);
      await settle();

      final future = hue.lights[2].set(true);
      expect(hue.lights[2].on, isTrue);
      await future;

      final f2 = hue.lights.first.setBrightness!(25);
      expect(hue.lights.first.brightness, 25);
      await f2;
      expect(bridge.lights.first['dimming'], {'brightness': 25});
    });

    test('błąd cofa stan i oznacza mostek jako niedostępny', () async {
      await hue.connect(paired);
      await settle();
      bridge.offline = true;

      await expectLater(hue.lights[2].set(true), throwsA(isA<HueException>()));

      expect(hue.lights[2].on, isFalse);
      expect(hue.reachable, isFalse);
      expect(hue.lights.first.status, 'Mostek niedostępny');
    });

    test('zapisany mostek wraca po restarcie, odłączenie go czyści', () async {
      await hue.connect(paired);
      final again = HueController(client: client, store: store);
      addTearDown(again.dispose);
      await again.load();
      expect(again.bridge?.id, 'BRIDGE01');

      await hue.disconnect();
      expect(store.saved, isNull);
      expect(hue.lights, isEmpty);
      expect(hue.hasDevices, isFalse);
    });

    test('odpytywanie działa tylko między start() a stop()', () async {
      await hue.connect(paired);
      await settle();
      Future<int> during(Duration d) async {
        final before = bridge.log.length;
        await Future<void>.delayed(d);
        return bridge.log.length - before;
      }

      expect(await during(const Duration(milliseconds: 200)), 0);
      hue.start();
      expect(await during(const Duration(milliseconds: 200)), greaterThan(4));
      hue.stop();
      await settle();
      expect(await during(const Duration(milliseconds: 200)), 0);
    });
  });

  group('na ekranie', () {
    testWidgets('parowanie: najpierw prośba o przycisk, potem połączenie',
        (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final hue = HueController(client: client, store: MemoryHueStore());
      addTearDown(hue.dispose);
      await tester.pumpWidget(MaterialApp(home: HueScreen(hue: hue)));

      await tester.enterText(find.byType(TextField), '10.0.0.2');
      await tester.pump();
      await tester.tap(find.text('Połącz').last);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      expect(find.textContaining('Naciśnij okrągły przycisk'), findsOneWidget);

      bridge.linkPressed = true;
      await tester.tap(find.text('Połącz').last);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Mostek 10.0.0.2'), findsOneWidget);
      expect(find.text('Salon'), findsOneWidget);
    });

    testWidgets('ekran Dom: lampa Hue z suwakiem jasności w szczegółach',
        (tester) async {
      final hue = HueController(
          client: client,
          store: MemoryHueStore(),
          pollInterval: const Duration(hours: 1));
      addTearDown(hue.dispose);
      await tester.runAsync(() async {
        await hue.connect(
            const HueBridge(id: 'BRIDGE01', host: '10.0.0.2', key: 'K'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      tester.view.physicalSize = const Size(390, 1400);
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
        home: HomeScreen(
          account: account,
          session: SessionController(),
          rooms: RoomsController(),
          tuya: TuyaController(),
          viessmann: ViessmannController(),
          faults: testFaults(),
          sources: [hue],
        ),
      ));
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Salon'), findsOneWidget);
      expect(find.byTooltip('Świeci 1 z 3 świateł'), findsOneWidget);

      await tester.longPress(find.text('Salon'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('Wyłącz'), findsOneWidget);
    });
  });
}
