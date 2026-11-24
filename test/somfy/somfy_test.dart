import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/screens/somfy_screen.dart';
import 'package:nestiq/somfy/somfy_client.dart';
import 'package:nestiq/somfy/somfy_controller.dart';
import 'package:nestiq/somfy/somfy_models.dart';
import 'package:nestiq/somfy/somfy_store.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';

import '../account/fake_server.dart';
import '../viessmann/fakes_faults.dart';

const pin = '2001-1234-5678';
const roller = 'io://$pin/11111111';
const awning = 'rts://$pin/22222222';

// Odpowiedzi zapisane według specyfikacji lokalnego API Somfy (openapi.yaml), nie z prawdziwej skrzynki.
List<Map<String, dynamic>> devices({int closure = 30, bool available = true}) =>
    [
      {
        'deviceURL': 'internal://$pin/pod/0',
        'label': 'TaHoma',
        'available': true,
        'states': [],
        'definition': {
          'commands': [
            {'commandName': 'refresh', 'nparams': 0},
          ],
        },
      },
      {
        'deviceURL': roller,
        'label': 'Roleta salon',
        'available': available,
        'states': [
          {'name': 'core:ClosureState', 'type': 1, 'value': closure},
          {
            'name': 'core:OpenClosedState',
            'type': 3,
            'value': closure == 0 ? 'open' : 'closed'
          },
        ],
        'definition': {
          'uiClass': 'RollerShutter',
          'commands': [
            {'commandName': 'open', 'nparams': 0},
            {'commandName': 'close', 'nparams': 0},
            {'commandName': 'stop', 'nparams': 0},
            {'commandName': 'setClosure', 'nparams': 1},
          ],
        },
      },
      {
        'deviceURL': awning,
        'label': 'Markiza',
        'available': true,
        'states': [],
        'definition': {
          'uiClass': 'Awning',
          'commands': [
            {'commandName': 'open', 'nparams': 0},
            {'commandName': 'close', 'nparams': 0},
            {'commandName': 'my', 'nparams': 0},
          ],
        },
      },
    ];

class MemorySomfyStore implements SomfyStore {
  SomfyGateway? saved;

  @override
  Future<SomfyGateway?> load() async => saved;

  @override
  Future<void> save(SomfyGateway gateway) async => saved = gateway;

  @override
  Future<void> clear() async => saved = null;
}

class FakeBox {
  final List<String> log = [];
  final List<http.Request> requests = [];
  bool offline = false;
  int? failWith;
  int closure = 30;
  String token = 'TOKEN';

  late final MockClient client = MockClient((request) async {
    log.add('${request.method} ${request.url.path}');
    requests.add(request);
    if (offline) throw http.ClientException('offline');
    if (failWith != null) return http.Response('{}', failWith!);
    if (request.headers['authorization'] != 'Bearer $token')
      return http.Response('{}', 401);
    final path =
        request.url.path.replaceFirst('/enduser-mobile-web/1/enduserAPI', '');
    if (path == '/setup') {
      return http.Response(
          jsonEncode({
            'gateways': [
              {'gatewayId': pin}
            ],
            'devices': []
          }),
          200);
    }
    if (path == '/setup/devices')
      return http.Response(jsonEncode(devices(closure: closure)), 200);
    if (request.method == 'POST' && path == '/exec/apply') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final cmd =
          ((body['actions'] as List).first as Map)['commands'][0] as Map;
      if (cmd['name'] == 'setClosure')
        closure = (cmd['parameters'] as List).first as int;
      if (cmd['name'] == 'open') closure = 0;
      if (cmd['name'] == 'close') closure = 100;
      return http.Response(jsonEncode({'execId': 'e1'}), 200);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  late FakeBox box;
  late SomfyClient client;
  const gw = SomfyGateway(id: pin, host: '10.0.0.8', token: 'TOKEN');

  setUp(() {
    box = FakeBox();
    client = SomfyClient(clientFor: (_) => box.client);
  });

  group('klient Somfy', () {
    test('PIN zamienia się w nazwę hosta skrzynki, adres IP zostaje', () {
      expect(SomfyClient.hostFor('2001-1234-5678'),
          'gateway-2001-1234-5678.local');
      expect(
          SomfyClient.hostFor(' https://192.168.1.20:8443/ '), '192.168.1.20');
      expect(SomfyClient.hostFor('tahoma.local'), 'tahoma.local');
    });

    test('połączenie sprawdza token i bierze PIN skrzynki z odpowiedzi',
        () async {
      final connected = await client.connect('192.168.1.20', ' TOKEN ');

      expect(connected.id, pin);
      expect(connected.host, '192.168.1.20');
      final request = box.requests.single;
      expect(request.url.port, 8443);
      expect(request.url.path, '/enduser-mobile-web/1/enduserAPI/setup');
      expect(request.headers['authorization'], 'Bearer TOKEN');
    });

    test('zły token i brak sieci dają czytelne błędy', () async {
      await expectLater(client.connect('10.0.0.8', 'ZLY'),
          throwsA(isA<SomfyException>().having((e) => e.code, 'code', 'auth')));
      box.offline = true;
      await expectLater(
          client.connect('10.0.0.8', 'TOKEN'),
          throwsA(
              isA<SomfyException>().having((e) => e.code, 'code', 'network')));
      await expectLater(
          client.connect('', 'TOKEN'),
          throwsA(
              isA<SomfyException>().having((e) => e.code, 'code', 'invalid')));
    });

    test('lista: tylko urządzenia z open i close, z pozycją i możliwościami',
        () async {
      final covers = await client.covers(gw);

      expect(covers.map((c) => c.name), ['Roleta salon', 'Markiza'],
          reason: 'skrzynka (pod) odpada');
      final shutter = covers.first;
      expect(shutter.closure, 30);
      expect(shutter.position, 70, reason: 'zamknięcie 30% to otwarcie 70%');
      expect(shutter.canSetPosition, isTrue);
      expect(shutter.stopCommand, 'stop');
      final rts = covers.last;
      expect(rts.position, isNull);
      expect(rts.canSetPosition, isFalse);
      expect(rts.stopCommand, 'my', reason: 'silniki RTS nie mają stop');
    });

    test('polecenia: góra/dół/stop i pozycja jako zamknięcie', () async {
      final covers = await client.covers(gw);
      box.requests.clear();

      await client.command(gw, covers.first, 'UP');
      await client.command(gw, covers.first, 'DOWN');
      await client.command(gw, covers.first, 'STOP');
      await client.command(gw, covers.first, '25%');
      await client.command(gw, covers.last, 'STOP');

      final bodies = [
        for (final r in box.requests) jsonDecode(r.body) as Map<String, dynamic>
      ];
      List commands(int i) =>
          (bodies[i]['actions'] as List).first['commands'] as List;
      expect(bodies.first['label'], 'NestIQ');
      expect((bodies.first['actions'] as List).first['deviceURL'], roller);
      expect(commands(0), [
        {'name': 'open'}
      ]);
      expect(commands(1), [
        {'name': 'close'}
      ]);
      expect(commands(2), [
        {'name': 'stop'}
      ]);
      expect(commands(3), [
        {
          'name': 'setClosure',
          'parameters': [75]
        }
      ]);
      expect(commands(4), [
        {'name': 'my'}
      ]);
      expect((bodies.last['actions'] as List).first['deviceURL'], awning);
    });

    test('pozycja na silniku bez setClosure jest odrzucana', () async {
      final covers = await client.covers(gw);
      await expectLater(
          client.command(gw, covers.last, '40%'),
          throwsA(isA<SomfyException>()
              .having((e) => e.code, 'code', 'unsupported')));
    });
  });

  group('kontroler Somfy', () {
    late MemorySomfyStore store;
    late SomfyController somfy;

    setUp(() {
      store = MemorySomfyStore();
      somfy = SomfyController(
        client: client,
        store: store,
        pollInterval: const Duration(milliseconds: 40),
        settleDelay: const Duration(milliseconds: 20),
      );
      addTearDown(somfy.dispose);
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('po połączeniu są rolety z kluczami do pokoi i statusami', () async {
      await somfy.connect(gw);
      await settle();

      final covers = somfy.covers;
      expect(covers.map((c) => c.name), ['Roleta salon', 'Markiza']);
      expect(covers.first.key, RoomsController.somfyKey(pin, roller));
      expect(covers.first.status, 'Otwarta w 70%');
      expect(covers.first.supportsPosition, isTrue);
      expect(covers.last.status, 'stan nieznany');
      expect(covers.last.supportsPosition, isFalse,
          reason: 'markiza RTS: tylko góra/stop/dół');
      expect(store.saved?.token, 'TOKEN');
    });

    test('polecenie zmienia pozycję od razu, a potem stan z urządzenia',
        () async {
      await somfy.connect(gw);
      await settle();

      final future = somfy.covers.first.command('DOWN');
      expect(somfy.covers.first.position, 0, reason: 'optymistycznie');
      await future;
      await settle();

      expect(box.closure, 100);
      expect(somfy.covers.first.status, 'Zamknięta');
    });

    test('błąd cofa pozycję i oznacza skrzynkę jako niedostępną', () async {
      await somfy.connect(gw);
      await settle();
      box.offline = true;

      await expectLater(
          somfy.covers.first.command('UP'), throwsA(isA<SomfyException>()));

      expect(somfy.covers.first.position, 70);
      expect(somfy.reachable, isFalse);
      expect(somfy.covers.first.status, 'Skrzynka niedostępna');
    });

    test('nieobsługiwane polecenie nie oznacza skrzynki jako niedostępnej',
        () async {
      await somfy.connect(gw);
      await settle();

      await expectLater(
          somfy.covers.last.command('40%'), throwsA(isA<SomfyException>()));
      expect(somfy.reachable, isTrue);
    });

    test('zapisana skrzynka wraca po restarcie, odłączenie ją czyści',
        () async {
      await somfy.connect(gw);
      final again = SomfyController(client: client, store: store);
      addTearDown(again.dispose);
      await again.load();
      expect(again.gateway?.id, pin);

      await somfy.disconnect();
      expect(store.saved, isNull);
      expect(somfy.covers, isEmpty);
    });

    test('odpytywanie działa tylko między start() a stop()', () async {
      await somfy.connect(gw);
      await settle();
      Future<int> during(Duration d) async {
        final before = box.log.length;
        await Future<void>.delayed(d);
        return box.log.length - before;
      }

      expect(await during(const Duration(milliseconds: 200)), 0);
      somfy.start();
      expect(await during(const Duration(milliseconds: 200)), greaterThan(2));
      somfy.stop();
      await settle();
      expect(await during(const Duration(milliseconds: 200)), 0);
    });
  });

  group('na ekranie', () {
    testWidgets('łączenie: zły token pokazuje błąd, dobry łączy',
        (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final somfy = SomfyController(
          client: client,
          store: MemorySomfyStore(),
          pollInterval: const Duration(hours: 1));
      addTearDown(somfy.dispose);
      await tester.pumpWidget(MaterialApp(home: SomfyScreen(somfy: somfy)));

      await tester.enterText(find.byType(TextField).first, '10.0.0.8');
      await tester.enterText(find.byType(TextField).last, 'ZLY');
      await tester.pump();
      await tester.ensureVisible(find.text('Połącz'));
      await tester.tap(find.text('Połącz'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      expect(find.textContaining('odrzuciła token'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'TOKEN');
      await tester.pump();
      await tester.tap(find.text('Połącz'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Skrzynka $pin'), findsOneWidget);
      expect(find.text('Roleta salon'), findsOneWidget);
    });

    testWidgets('ekran Dom: roleta z suwakiem, markiza RTS bez suwaka',
        (tester) async {
      final somfy = SomfyController(
          client: client,
          store: MemorySomfyStore(),
          pollInterval: const Duration(hours: 1));
      addTearDown(somfy.dispose);
      await tester.runAsync(() async {
        await somfy.connect(gw);
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
          sources: [somfy],
        ),
      ));
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byTooltip('Rolety').first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Roleta salon'), findsOneWidget);
      expect(find.text('Markiza'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget,
          reason: 'suwak tylko tam, gdzie jest setClosure');
      // Bez pokoi jest jedna sekcja „Wszystkie urządzenia” z podsumowaniem.
      expect(find.text('2 rolet'), findsOneWidget);
    });
  });
}
