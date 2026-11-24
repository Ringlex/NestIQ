import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/tuya/tuya_models.dart';
import 'package:nestiq/tuya/tuya_store.dart';

import 'fakes.dart';

const channels = [
  TuyaChannel(dpId: 1, code: 'switch_1', name: 'Przycisk 1'),
  TuyaChannel(dpId: 2, code: 'switch_2', name: 'Przycisk 2'),
];

TuyaDevice device({String? ip = '192.168.1.50', String version = '3.3'}) =>
    TuyaDevice(
      id: 'dev1',
      name: 'Salon',
      localKey: '0123456789abcdef',
      version: version,
      ip: ip,
      channels: channels,
    );

const creds = TuyaCloudCredentials(accessId: 'id', accessSecret: 'secret');

void main() {
  late World world;
  late FakeCloud cloud;
  late MemoryTuyaStore store;

  Future<TuyaController> build({
    TuyaDevice? dev,
    TuyaMode mode = TuyaMode.auto,
    TuyaCloudCredentials? credentials = creds,
    Future<List<TuyaDiscovered>> Function()? discoverer,
  }) async {
    world = World();
    cloud = FakeCloud();
    store = MemoryTuyaStore()
      ..saved = StoredTuya(
          credentials: credentials, devices: [dev ?? device()], mode: mode);
    final controller = TuyaController(
      store: store,
      lanFactory: (d, v) => FakeLink(v, world: world),
      cloudFactory: (_) => cloud,
      discoverer: discoverer,
      cloudPollInterval: const Duration(milliseconds: 40),
      retryBase: const Duration(milliseconds: 20),
    );
    await controller.load();
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  group('połączenie lokalne', () {
    test('wykrywa wersję protokołu, zapamiętuje ją i wczytuje stan', () async {
      final c = await build();
      c.start();
      await settle();

      expect(world.connectAttempts, ['3.3', '3.4']);
      expect(c.routeOf('dev1'), TuyaRoute.local);
      expect(c.isOn('dev1', 1), isFalse);
      expect(c.isOn('dev1', 2), isTrue);
      expect(c.devices.single.version, '3.4');
      expect(store.saved.devices.single.version, '3.4');
    });

    test('zmiana z fizycznego przycisku dociera przez push', () async {
      final c = await build();
      c.start();
      await settle();

      world.links.last.push({'1': true});
      await settle();

      expect(c.isOn('dev1', 1), isTrue);
    });

    test('przełączenie idzie siecią lokalną, bez chmury', () async {
      final c = await build();
      c.start();
      await settle();

      await c.setChannel(c.devices.single, channels[0], true);

      expect(world.setCalls, [
        {'1': true},
      ]);
      expect(cloud.commands, isEmpty);
      expect(c.isOn('dev1', 1), isTrue);
    });

    test('po zerwaniu połączenia łączy się ponownie', () async {
      final c = await build(dev: device(version: '3.4'));
      c.start();
      await settle();
      expect(world.links, hasLength(1));

      world.links.first.drop();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(world.links.length, greaterThan(1));
      expect(c.routeOf('dev1'), TuyaRoute.local);
    });
  });

  group('chmura jako zapas', () {
    test('gdy polecenie lokalne zawiedzie, trafia do chmury', () async {
      final c = await build(dev: device(version: '3.4'));
      c.start();
      await settle();
      world.failSet = true;

      await c.setChannel(c.devices.single, channels[1], false);

      expect(cloud.commands, [('dev1', 'switch_2', false)]);
      expect(c.isOn('dev1', 2), isFalse);
      expect(c.routeOf('dev1'), TuyaRoute.cloud);
    });

    test('urządzenie bez adresu IP działa przez chmurę i pobiera stan',
        () async {
      final c = await build(dev: device(ip: null));
      c.start();
      await settle();

      expect(c.routeOf('dev1'), TuyaRoute.cloud);
      expect(c.isOn('dev1', 1), isTrue);
      expect(c.isOn('dev1', 2), isFalse);
      expect(world.connectAttempts, isEmpty);

      await c.setChannel(c.devices.single, channels[1], true);
      expect(cloud.commands, [('dev1', 'switch_2', true)]);
    });

    test('tryb „tylko lokalnie” nigdy nie używa chmury', () async {
      final c = await build(dev: device(version: '3.4'), mode: TuyaMode.local);
      c.start();
      await settle();
      world.failSet = true;

      await expectLater(c.setChannel(c.devices.single, channels[0], true),
          throwsA(isA<TuyaControlException>()));

      expect(cloud.commands, isEmpty);
      expect(c.isOn('dev1', 1), isFalse,
          reason: 'stan wraca do poprzedniego po błędzie');
    });

    test('tryb „tylko chmura” nie otwiera połączeń lokalnych', () async {
      final c = await build(mode: TuyaMode.cloud);
      c.start();
      await settle();

      expect(world.connectAttempts, isEmpty);
      expect(c.routeOf('dev1'), TuyaRoute.cloud);
    });

    test('bez adresu i bez chmury sterowanie kończy się czytelnym błędem',
        () async {
      final c = await build(dev: device(ip: null), credentials: null);
      c.start();
      await settle();

      expect(c.routeOf('dev1'), TuyaRoute.offline);
      await expectLater(
        c.setChannel(c.devices.single, channels[0], true),
        throwsA(isA<TuyaControlException>().having(
            (e) => e.message, 'message', contains('nie jest dostępny'))),
      );
      expect(c.isOn('dev1', 1), isNull);
    });

    test('niedostępna chmura oznacza urządzenie jako offline i podaje powód',
        () async {
      final c = await build(dev: device(ip: null));
      cloud.offline = true;
      c.start();
      await settle();

      expect(c.routeOf('dev1'), TuyaRoute.offline);
      expect(c.problemOf('dev1'),
          allOf(contains('brak adresu IP'), contains('chmura: brak chmury')));
    });

    test('powód znika, gdy urządzenie zaczyna działać', () async {
      final c = await build(dev: device(ip: null));
      cloud.offline = true;
      c.start();
      await settle();
      expect(c.problemOf('dev1'), isNotNull);

      cloud.offline = false;
      await c.refresh();

      expect(c.routeOf('dev1'), TuyaRoute.cloud);
      expect(c.problemOf('dev1'), contains('brak adresu IP'),
          reason: 'to nadal prawda, ale chmura już działa');
      expect(c.problemOf('dev1'), isNot(contains('chmura:')));
    });

    test('nieudane połączenie lokalne zapamiętuje przyczynę', () async {
      final c = await build();
      world.acceptedVersion = '9.9'; // żadna wersja nie pasuje
      c.start();
      await settle();

      expect(c.problemOf('dev1'), contains('sieć lokalna'));
    });
  });

  group('konfiguracja', () {
    test(
        'import z chmury dopisuje nowe urządzenia i zachowuje adres, wersję oraz nazwę',
        () async {
      final c = await build(dev: device(version: '3.5'));
      cloud.devices = [
        const TuyaDevice(
            id: 'dev1',
            name: 'Salon (chmura)',
            localKey: 'fedcba9876543210',
            channels: channels),
        const TuyaDevice(
            id: 'dev2',
            name: 'Kuchnia',
            localKey: '1111111111111111',
            channels: [
              TuyaChannel(dpId: 1, code: 'switch_1', name: 'Przycisk 1'),
            ]),
      ];

      final result = await c.importFromCloud(creds);

      expect(result.added, 1);
      expect(result.total, 2);
      final dev1 = c.devices.firstWhere((d) => d.id == 'dev1');
      expect(dev1.ip, '192.168.1.50');
      expect(dev1.version, '3.5');
      expect(dev1.name, 'Salon', reason: 'własna nazwa nie jest nadpisywana');
      expect(dev1.localKey, 'fedcba9876543210',
          reason: 'klucz odświeżony z chmury');
      expect(store.saved.devices.map((d) => d.id), ['dev1', 'dev2']);
      expect(store.saved.credentials?.accessId, 'id');
    });

    test('skanowanie sieci uzupełnia adres i wersję', () async {
      final c = await build(
        dev: device(ip: null),
        discoverer: () async => [
          const TuyaDiscovered(id: 'dev1', ip: '192.168.1.77', version: '3.4')
        ],
      );

      final matched = await c.discover();

      expect(matched, 1);
      expect(c.devices.single.ip, '192.168.1.77');
      expect(c.devices.single.version, '3.4');
      expect(store.saved.devices.single.ip, '192.168.1.77');
    });

    test('usunięcie urządzenia zamyka połączenie i czyści stan', () async {
      final c = await build(dev: device(version: '3.4'));
      c.start();
      await settle();

      await c.removeDevice('dev1');

      expect(c.devices, isEmpty);
      expect(c.isOn('dev1', 1), isNull);
      expect(world.links.single.isConnected, isFalse);
    });

    test('zmiana trybu jest zapisywana', () async {
      final c = await build();
      await c.setMode(TuyaMode.cloud);
      expect(store.saved.mode, TuyaMode.cloud);
    });
  });
}
