import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/mobilus/proto.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/tuya/tuya_models.dart';
import 'package:nestiq/tuya/tuya_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tuya/fakes.dart';
import '../viessmann/fakes_faults.dart';
import 'fake_server.dart';

// Typ 5 = SWITCH (światło), 1 = SENSO (roleta).
const light = 5;
const blind = 1;

void main() {
  late RoomsController rooms;
  late SessionController session;
  late TuyaController tuya;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    rooms = RoomsController();
    final salon = await rooms.add('Salon');
    final kids = await rooms.add('Pokój dziecka');
    await rooms.assign(1, salon.id);
    await rooms.assign(2, salon.id);
    await rooms.assign(3, kids.id);
    await rooms.assign(10, salon.id);
    await rooms.assign(11, kids.id);

    tuya = TuyaController();
    session = SessionController()
      ..phase = SessionPhase.connected
      ..devices = const [
        Device(id: 1, name: 'Główne', type: light),
        Device(id: 2, name: 'Kinkiety', type: light),
        Device(id: 3, name: 'Sufit dziecka', type: light),
        Device(id: 4, name: 'Korytarz bez pokoju', type: light),
        Device(id: 10, name: 'Okno salon', type: blind),
        Device(id: 11, name: 'Okno dziecka', type: blind),
      ];
  });

  Future<void> pumpHome(WidgetTester tester, Profile profile) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final account = AccountController(
      api: NestIqApi(
          baseUrl: 'http://test', client: FakeServer((_) => null).client),
      store: MemoryStore(),
    )
      ..active = profile
      ..phase = AccountPhase.active;
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
          account: account,
          session: session,
          rooms: rooms,
          tuya: tuya,
          viessmann: ViessmannController(),
          faults: testFaults()),
    ));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('administrator widzi wszystkie pokoje i urządzenia bez pokoju',
      (tester) async {
    await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));

    expect(find.text('Salon'), findsOneWidget);
    expect(find.text('Pokój dziecka'), findsOneWidget);
    expect(find.text('Pozostałe'), findsOneWidget);
    expect(find.text('Korytarz bez pokoju'), findsOneWidget);
    expect(find.text('Okno salon'), findsNothing); // to zakładka Rolety
  });

  testWidgets('profil ograniczony do pokoju dziecka widzi tylko jego',
      (tester) async {
    final kids = rooms.rooms.last.id;
    final profile = Profile.fromJson({
      ...profileJson('k', 'Dziecko', role: 'restricted'),
      'allowedRooms': [kids],
    });
    await pumpHome(tester, profile);

    expect(find.text('Sufit dziecka'), findsOneWidget);
    expect(find.text('Główne'), findsNothing);
    expect(find.text('Pozostałe'), findsNothing);
    expect(find.text('Korytarz bez pokoju'), findsNothing);
  });

  testWidgets(
      'Dziecko może przełączać światła, a komunikat wyjaśnia ograniczenia',
      (tester) async {
    await pumpHome(tester,
        Profile.fromJson(profileJson('k', 'Dziecko', role: 'restricted')));

    final switches = tester.widgetList<Switch>(find.byType(Switch));
    expect(switches, isNotEmpty);
    expect(switches.every((s) => s.onChanged != null), isTrue);
    expect(find.textContaining('Sceny i ustawienia zmienia administrator'),
        findsOneWidget);
  });

  testWidgets('bez prawa sterowania światłami przełączniki są nieaktywne',
      (tester) async {
    final locked =
        Profile.fromJson(profileJson('m', 'Gość', role: 'member', permissions: {
      'controlLights': false,
      'controlBlinds': true,
      'runScenes': false,
      'editScenes': false,
      'manageSettings': false,
    }));
    await pumpHome(tester, locked);

    expect(
        tester
            .widgetList<Switch>(find.byType(Switch))
            .every((s) => s.onChanged == null),
        isTrue);
    expect(find.textContaining('nie ma uprawnień do sterowania światłami'),
        findsOneWidget);
  });

  group('ułatwienia na ekranie Dom', () {
    testWidgets('podsumowanie na górze podaje stan świateł i rolet',
        (tester) async {
      await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));

      expect(find.byTooltip('Światła wyłączone'), findsOneWidget);
      expect(find.byTooltip('Rolety zamknięte'), findsOneWidget);

      await tester.tap(find.byTooltip('Rolety zamknięte'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
          find.text('Okno salon'), findsOneWidget); // chip przełączył zakładkę
    });

    testWidgets('zaznaczona zakładka ma ikonę i napis, pozostałe tylko ikonę',
        (tester) async {
      await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));

      expect(find.text('Oświetlenie'), findsOneWidget);
      expect(find.text('Rolety'), findsNothing);
      expect(find.byTooltip('Rolety'), findsOneWidget,
          reason: 'nazwa zostaje w podpowiedzi i dla czytników ekranu');

      await tester.tap(find.byTooltip('Rolety'));
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Rolety'), findsOneWidget);
      expect(find.text('Oświetlenie'), findsNothing);
    });

    testWidgets('przyciski zbiorcze są tylko w pokoju z kilkoma światłami',
        (tester) async {
      await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));

      // Salon ma dwa światła, pozostałe pokoje po jednym.
      expect(find.text('Włącz w pokoju'), findsOneWidget);
      expect(find.text('Wyłącz w pokoju'), findsOneWidget);
    });

    testWidgets('bez uprawnień nie ma przycisków zbiorczych', (tester) async {
      final locked = Profile.fromJson(
          profileJson('m', 'Gość', role: 'member', permissions: {
        'controlLights': false,
        'controlBlinds': false,
        'runScenes': false,
        'editScenes': false,
        'manageSettings': false,
      }));
      await pumpHome(tester, locked);
      expect(find.text('Włącz w pokoju'), findsNothing);
    });

    testWidgets('przytrzymanie światła otwiera szczegóły', (tester) async {
      await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));

      await tester.pump(const Duration(seconds: 1)); // kończy kaskadę FadeUp
      await tester.longPress(find.text('Główne'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Włącz'), findsOneWidget);
      expect(find.text('stan nieznany'), findsWidgets);
    });

    testWidgets('przytrzymanie rolety otwiera duże sterowanie', (tester) async {
      await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));
      await tester.tap(find.byTooltip('Rolety zamknięte'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));

      await tester.longPress(find.text('Okno salon'));
      await tester.pump(const Duration(milliseconds: 500));

      // Ten sam tytuł jest teraz na liście i w arkuszu.
      expect(find.text('Okno salon'), findsNWidgets(2));
    });

    testWidgets('wskazówka o gestach pokazuje się raz', (tester) async {
      await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));
      expect(find.textContaining('Dotknij światła'), findsOneWidget);

      await tester.tap(find.byTooltip('Zamknij wskazówkę'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Dotknij światła'), findsNothing);

      // Po ponownym uruchomieniu nie wraca.
      await tester.pumpWidget(const SizedBox());
      await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));
      expect(find.textContaining('Dotknij światła'), findsNothing);
    });
  });

  testWidgets('zakładka Rolety pokazuje rolety, nie światła', (tester) async {
    await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));

    await tester.tap(find.byTooltip('Rolety'));
    await tester.pumpAndSettle();

    expect(find.text('Okno salon'), findsOneWidget);
    expect(find.text('Główne'), findsNothing);
  });

  testWidgets(
      'bez połączenia z bramką administrator dostaje przycisk połączenia',
      (tester) async {
    session.phase = SessionPhase.loggedOut;
    await pumpHome(tester, Profile.fromJson(profileJson('a', 'Mama')));

    expect(find.text('Połącz z bramką'), findsOneWidget);
  });

  tuyaTests();

  testWidgets('bez połączenia z bramką Dziecko jest odesłane do administratora',
      (tester) async {
    session.phase = SessionPhase.loggedOut;
    await pumpHome(tester,
        Profile.fromJson(profileJson('k', 'Dziecko', role: 'restricted')));

    expect(find.text('Połącz z bramką'), findsNothing);
    expect(find.textContaining('Poproś administratora'), findsOneWidget);
  });
}

// ---------------------------------------------------------------- światła Tuya

void tuyaTests() {
  group('światła Tuya na ekranie Dom', () {
    late RoomsController rooms;
    late SessionController session;
    late World world;
    late FakeCloud cloud;
    late TuyaController tuya;

    const channels = [
      TuyaChannel(dpId: 1, code: 'switch_1', name: 'Przycisk 1'),
      TuyaChannel(dpId: 2, code: 'switch_2', name: 'Przycisk 2'),
    ];

    Future<void> setUpTuya(
        {String? ip = '192.168.1.50', bool withCloud = true}) async {
      SharedPreferences.setMockInitialValues({});
      rooms = RoomsController();
      final salon = await rooms.add('Salon');
      await rooms.assignKey(RoomsController.tuyaKey('dev1', 1), salon.id);
      await rooms.assignKey(RoomsController.tuyaKey('dev1', 2), salon.id);

      session = SessionController()
        ..phase = SessionPhase.loggedOut; // bez bramki Mobilus
      world = World()..acceptedVersion = '3.3';
      cloud = FakeCloud();
      tuya = TuyaController(
        store: MemoryTuyaStore()
          ..saved = StoredTuya(
            credentials: withCloud
                ? const TuyaCloudCredentials(accessId: 'a', accessSecret: 'b')
                : null,
            devices: [
              TuyaDevice(
                  id: 'dev1',
                  name: 'Salon',
                  localKey: '0123456789abcdef',
                  ip: ip,
                  channels: channels),
            ],
          ),
        lanFactory: (d, v) => FakeLink(v, world: world),
        cloudFactory: (_) => cloud,
        cloudPollInterval: const Duration(seconds: 30),
        retryBase: const Duration(milliseconds: 30),
      );
      await tuya.load();
      addTearDown(tuya.dispose);
    }

    Future<void> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 1200);
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
            session: session,
            rooms: rooms,
            tuya: tuya,
            viessmann: ViessmannController(),
            faults: testFaults()),
      ));
      tuya.start();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets(
        'światła Tuya są widoczne bez bramki Mobilus, z drogą sterowania',
        (tester) async {
      await setUpTuya();
      await pumpHome(tester);

      expect(find.text('Salon'), findsWidgets); // nazwa pokoju
      expect(find.text('Salon · Przycisk 1'), findsOneWidget);
      expect(find.text('Salon · Przycisk 2'), findsOneWidget);
      expect(find.textContaining('Wyłączone · lokalnie'), findsOneWidget);
      expect(find.textContaining('Włączone · lokalnie'), findsOneWidget);
      expect(find.textContaining('Połącz z bramką'), findsNothing);
    });

    testWidgets('przełącznik wysyła polecenie siecią lokalną', (tester) async {
      await setUpTuya();
      await pumpHome(tester);

      await tester.tap(find.byType(Switch).first);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(world.setCalls, [
        {'1': true},
      ]);
      expect(cloud.commands, isEmpty);
    });

    testWidgets(
        'urządzenie bez adresu IP działa przez chmurę i jest tak oznaczone',
        (tester) async {
      await setUpTuya(ip: null);
      await pumpHome(tester);

      expect(find.textContaining('· chmura'), findsWidgets);

      await tester.tap(find.byType(Switch).first);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(cloud.commands, [('dev1', 'switch_1', false)],
          reason: 'światło 1 było włączone w chmurze');
      tuya.stop(); // anuluje zaplanowany odczyt stanu po poleceniu
    });

    testWidgets('niedostępne urządzenie ma wyszarzony przełącznik',
        (tester) async {
      await setUpTuya(ip: null, withCloud: false);
      await pumpHome(tester);

      expect(find.text('Niedostępne'), findsNWidgets(2));
      expect(
          tester
              .widgetList<Switch>(find.byType(Switch))
              .every((s) => s.onChanged == null),
          isTrue);
    });

    testWidgets(
        '„Wyłącz wszystkie” wyłącza włączone światła Tuya i da się cofnąć',
        (tester) async {
      await setUpTuya();
      await pumpHome(tester);
      expect(world.dps['2'], true);

      await tester.tap(find.text('Wyłącz wszystkie'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(world.setCalls, [
        {'2': false},
      ]);
      expect(find.text('Wyłączono 1 światło'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Cofnij'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(world.setCalls.last, {'2': true});
    });
  });
}
