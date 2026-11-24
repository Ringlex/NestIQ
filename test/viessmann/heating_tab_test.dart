import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/heating_detail_screens.dart';
import 'package:nestiq/screens/heating_view.dart';
import 'package:nestiq/widgets/heating_cards.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_auth.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/viessmann/viessmann_models.dart';
import 'package:nestiq/viessmann/viessmann_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/fake_server.dart';
import 'fakes_faults.dart';
import 'fakes.dart';
import 'fixtures.dart';

/// Przejście do nowego ekranu i animacje potrzebują kilku klatek.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  late FakeViessmannApi api;

  Future<ViessmannController> controller({
    bool configured = true,
    Duration poll = const Duration(minutes: 10),
  }) async {
    final store = MemoryViessmannStore();
    if (configured) {
      store.saved = const StoredViessmann(
        clientId: '1561f44a5fbce8acf0c3cea9334e5af1',
        refreshToken: 'R',
        device: testDevice,
      );
    }
    final c = ViessmannController(
      store: store,
      auth: ViessmannAuth(),
      apiFactory: ({required token, required onCall}) =>
          api = FakeViessmannApi(onCall),
      pollInterval: poll,
      minRefreshGap: Duration.zero,
      settleDelay: Duration.zero,
      isInForeground: () => true,
    );
    await c.load();
    addTearDown(c.dispose);
    return c;
  }

  Profile profile(String role, {bool heating = true}) => Profile.fromJson({
        ...profileJson('p', 'Test', role: role),
        'permissions': {
          'controlLights': true,
          'controlBlinds': true,
          'controlHeating': heating,
          'runScenes': true,
          'editScenes': role == 'admin',
          'manageSettings': role == 'admin',
        },
      });

  void phone(WidgetTester tester) {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpHome(
      WidgetTester tester, ViessmannController v, Profile active) async {
    phone(tester);
    final account = AccountController(
      api: NestIqApi(
          baseUrl: 'http://test', client: FakeServer((_) => null).client),
      store: MemoryStore(),
    )
      ..active = active
      ..phase = AccountPhase.active;
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        account: account,
        session: SessionController()..phase = SessionPhase.loggedOut,
        rooms: RoomsController(),
        tuya: TuyaController(),
        viessmann: v,
        faults: testFaults(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openHeating(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Ogrzewanie').first);
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    // Dwa odświeżenia: pierwszy uruchamia odczyt, drugi rysuje jego wynik.
    await settle(tester);
    await settle(tester);
  }

  Future<void> pumpView(WidgetTester tester, ViessmannController v,
      {bool canControl = true, bool canManage = true}) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HeatingView(
            viessmann: v,
            canControl: canControl,
            canManage: canManage,
            onSetup: () {}),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  group('zakładka Ogrzewanie', () {
    testWidgets('widać ją tylko z uprawnieniem sterowania ogrzewaniem',
        (tester) async {
      await pumpHome(tester, await controller(), profile('member'));
      expect(find.byTooltip('Ogrzewanie'), findsOneWidget);
    });

    testWidgets('profil bez uprawnienia nie ma zakładki', (tester) async {
      await pumpHome(
          tester, await controller(), profile('restricted', heating: false));
      expect(find.byTooltip('Ogrzewanie'), findsNothing);
      expect(find.byTooltip('Rolety'), findsOneWidget);
    });

    testWidgets('bez połączenia administrator dostaje przycisk',
        (tester) async {
      await pumpHome(
          tester, await controller(configured: false), profile('admin'));
      await openHeating(tester);
      expect(find.text('Połącz z Viessmann'), findsOneWidget);
    });

    testWidgets('bez połączenia domownik dostaje wyjaśnienie, bez przycisku',
        (tester) async {
      await pumpHome(
          tester, await controller(configured: false), profile('member'));
      await openHeating(tester);
      expect(find.text('Połącz z Viessmann'), findsNothing);
      expect(find.textContaining('Poproś administratora'), findsOneWidget);
    });

    testWidgets('pokazuje stan pieca z odpowiedzi API', (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);

      expect(find.text('49,6 °C'), findsOneWidget); // zasobnik
      expect(find.text('50,7 °C'), findsOneWidget); // zasilanie
      expect(find.text('31 °C'), findsOneWidget,
          reason: 'nastawa obiegu, jak w ViCare');
      expect(find.text('Nastawa obiegu'), findsOneWidget);
      expect(find.text('Kocioł'), findsNothing,
          reason: 'temperatura kotła z pieca jest niewiarygodna');
      expect(find.text('Palnik wyłączony'), findsOneWidget);
      expect(find.textContaining('Tryb: Komfort'), findsOneWidget);
      expect(find.textContaining('Tryb: Ogrzewanie'), findsOneWidget);
      expect(find.text('S.6'), findsOneWidget);
      expect(find.textContaining('700 h pracy'), findsOneWidget);
    });

    testWidgets(
        'dotknięcie karty „Ciepła woda” otwiera ekran z temperaturą i trybem',
        (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);

      await tester.tap(find.text('Ciepła woda'));
      await settle(tester);

      expect(find.byType(HotWaterScreen), findsOneWidget);
      expect(find.byType(TemperatureEditor), findsOneWidget);
      expect(find.text('Zakres: 30–60 °C, krok 1'), findsOneWidget);
    });

    testWidgets('dotknięcie karty „Ogrzewanie” otwiera ekran nastawy obiegu',
        (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);

      await tester.tap(find.text('Nastawa obiegu'));
      await settle(tester);

      expect(find.byType(HeatingCircuitScreen), findsOneWidget);
      expect(find.text('31 °C'), findsWidgets);
      expect(find.text('Zakres: 20–80 °C, krok 1'), findsOneWidget);
    });

    testWidgets(
        'zmiana temperatury c.w.u. wymaga „Zapisz” i dopiero wtedy idzie do pieca',
        (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);
      await tester.tap(find.text('Ciepła woda'));
      await settle(tester);

      await tester.tap(find.byTooltip('Więcej'));
      await tester.tap(find.byTooltip('Więcej'));
      await settle(
          tester); // animacja rozwinięcia przycisku „Zapisz” startuje w kolejnej klatce
      expect(find.text('50 °C'), findsOneWidget);
      expect(api.executed, isEmpty,
          reason: 'sama zmiana na ekranie niczego nie wysyła');

      await tester.tap(find.text('Zapisz 50 °C'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);

      expect(api.executed.single.$2, 'setTargetTemperature');
      expect(api.executed.single.$3, {'temperature': 50});
    });

    testWidgets('„Cofnij” odrzuca niezapisaną zmianę', (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);
      await tester.tap(find.text('Ciepła woda'));
      await settle(tester);

      await tester.tap(find.byTooltip('Mniej'));
      await settle(
          tester); // animacja rozwinięcia przycisku „Zapisz” startuje w kolejnej klatce
      expect(find.text('47 °C'), findsOneWidget);
      await tester.tap(find.text('Cofnij'));
      await settle(
          tester); // animacja rozwinięcia przycisku „Zapisz” startuje w kolejnej klatce

      expect(find.text('Zapisz 47 °C'), findsNothing);
      expect(find.text('48 °C'), findsOneWidget);
      expect(api.executed, isEmpty);
    });

    testWidgets(
        'nastawa obiegu: mała zmiana idzie od razu, duża pyta o potwierdzenie',
        (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);
      await tester.tap(find.text('Nastawa obiegu'));
      await settle(tester);

      // Małe przesunięcie: +2 °C.
      await tester.tap(find.byTooltip('Więcej'));
      await tester.tap(find.byTooltip('Więcej'));
      await settle(
          tester); // animacja rozwinięcia przycisku „Zapisz” startuje w kolejnej klatce
      await tester.tap(find.text('Zapisz 33 °C'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(api.executed.single.$2, 'setTemperature');
      expect(api.executed.single.$3, {'targetTemperature': 33});
      expect(find.text('Duża zmiana nastawy'), findsNothing);

      // Duże przesunięcie: przeciągnięcie suwaka daleko w prawo (do 80 °C).
      await tester.drag(find.byType(Slider), const Offset(600, 0));
      await settle(
          tester); // animacja rozwinięcia przycisku „Zapisz” startuje w kolejnej klatce
      await tester.tap(find.textContaining('Zapisz'));
      await settle(tester);
      expect(find.text('Duża zmiana nastawy'), findsOneWidget);

      await tester.tap(find.text('Anuluj'));
      await settle(tester);
      expect(api.executed.length, 1,
          reason: 'odmowa potwierdzenia nic nie wysyła');
    });

    testWidgets('zmiana trybu ciepłej wody wysyła polecenie', (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);
      await tester.tap(find.text('Ciepła woda'));
      await settle(tester);

      await tester.tap(find.text('Eko'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);

      expect(api.executed.single.$2, 'setMode');
      expect(api.executed.single.$3, {'mode': 'eco'});
    });

    testWidgets('wyłączenie c.w.u. wymaga potwierdzenia', (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);
      await tester.tap(find.text('Ciepła woda'));
      await settle(tester);

      await tester.tap(find.text('Wyłączona'));
      await settle(tester);
      expect(find.text('Wyłączyć ciepłą wodę?'), findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await settle(tester);

      expect(api.executed, isEmpty, reason: 'anulowanie nic nie wysyła');
    });

    testWidgets(
        'czuwanie ogrzewania wymaga potwierdzenia i blokuje edycję nastawy',
        (tester) async {
      await pumpHome(tester, await controller(), profile('admin'));
      await openHeating(tester);
      await tester.tap(find.text('Nastawa obiegu'));
      await settle(tester);

      await tester.tap(find.text('Czuwanie'));
      await settle(tester);
      expect(find.text('Przełączyć w czuwanie?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Czuwanie'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      await settle(tester);

      expect(api.executed.single.$3, {'mode': 'standby'});
      expect(find.textContaining('Ogrzewanie jest w czuwaniu'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    });

    testWidgets('bez uprawnienia do sterowania edytor i tryby są nieaktywne',
        (tester) async {
      final v = await controller();
      await v.refresh(force: true);
      phone(tester);
      await tester.pumpWidget(
          MaterialApp(home: HotWaterScreen(viessmann: v, canControl: false)));
      await settle(tester);

      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      expect(
          tester
              .widgetList<ChoiceChip>(find.byType(ChoiceChip))
              .every((c) => c.onSelected == null),
          isTrue);
    });

    testWidgets('odpytywanie trwa tylko przy otwartej zakładce',
        (tester) async {
      final v = await controller(poll: const Duration(milliseconds: 80));
      await pumpHome(tester, v, profile('admin'));
      expect(v.state, isNull, reason: 'inne zakładki nie czytają pieca');

      await tester.tap(find.byTooltip('Ogrzewanie').first);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final whileOpen = api.featureCalls;
      expect(whileOpen, greaterThan(1));

      await tester.tap(find.byTooltip('Rolety'));
      // Wychodząca zakładka znika po zakończeniu przejścia; potem już nie odpytuje.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      final afterLeaving = api.featureCalls;
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.featureCalls, afterLeaving,
          reason: 'po wyjściu z zakładki odczyty ustają');
    });

    testWidgets(
        'wygasła sesja pokazuje baner z logowaniem i zostawia ostatni stan',
        (tester) async {
      final v = await controller();
      await v.refresh(force: true);
      api.failWith = const ViessmannException(
          'Sesja Viessmanna wygasła. Zaloguj się ponownie.',
          status: 401);
      await v.refresh(force: true);
      expect(v.sessionExpired, isTrue);

      await pumpView(tester, v);

      expect(find.textContaining('Sesja Viessmanna wygasła'), findsOneWidget);
      expect(find.text('Zaloguj'), findsOneWidget);
      expect(find.text('49,6 °C'), findsOneWidget);
    });

    testWidgets('blokada awaryjna pieca jest widocznym ostrzeżeniem',
        (tester) async {
      final v = await controller();
      await v.refresh(force: true);
      api.data = vitodensFeatures()
          .map((f) => f['feature'] == 'device.lock.malfunction'
              ? feat('device.lock.malfunction', props: {'active': flag(true)})
              : f)
          .toList();
      await v.refresh(force: true);
      expect(v.state!.malfunction, isTrue);

      await pumpView(tester, v);

      expect(find.textContaining('Blokada awaryjna pieca'), findsWidgets);
      expect(find.text('Zobacz'), findsOneWidget);
    });
  });
}
