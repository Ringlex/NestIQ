import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/household/household_controller.dart';
import 'package:nestiq/mobilus/proto.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/screens/home_shell.dart';
import 'package:nestiq/screens/planner/planner_screen.dart';
import 'package:nestiq/state/app_settings.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/scenes_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/widgets/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/fake_server.dart';
import '../viessmann/fakes_faults.dart';

const phone = Size(390, 844);
const tabletPortrait = Size(800, 1280);
const tabletLandscape = Size(1280, 800);

void main() {
  late AccountController account;
  late RoomsController rooms;
  late SessionController session;
  late HouseholdController household;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final server = FakeServer((r) {
      switch ('${r.method} ${r.url.path}') {
        case 'GET /v1/lists':
          return (200, {'lists': []});
        case 'GET /v1/reminders':
          return (200, {'reminders': []});
        case 'GET /v1/events':
          return (200, {'events': []});
        case 'GET /v1/messages':
          return (200, {'messages': [], 'unread': 0});
      }
      return (200, {'status': 'ok'});
    });
    final api = NestIqApi(baseUrl: 'http://test', client: server.client)
      ..accessToken = 'tok';
    account = AccountController(api: api, store: MemoryStore())
      ..profiles = [Profile.fromJson(profileJson('a', 'Mama'))]
      ..active = Profile.fromJson(profileJson('a', 'Mama'))
      ..phase = AccountPhase.active;
    household =
        HouseholdController(api: api, pollInterval: const Duration(hours: 1));
    addTearDown(household.dispose);

    rooms = RoomsController();
    final salon = await rooms.add('Salon');
    final kitchen = await rooms.add('Kuchnia');
    final bedroom = await rooms.add('Sypialnia');
    await rooms.assign(1, salon.id);
    await rooms.assign(2, kitchen.id);
    await rooms.assign(3, bedroom.id);
    await rooms.assign(10, salon.id);
    await rooms.assign(11, kitchen.id);
    session = SessionController()
      ..phase = SessionPhase.connected
      ..devices = const [
        Device(id: 1, name: 'Lampa salon', type: 5),
        Device(id: 2, name: 'Lampa kuchnia', type: 5),
        Device(id: 3, name: 'Lampa sypialnia', type: 5),
        Device(id: 10, name: 'Okno salon', type: 1),
        Device(id: 11, name: 'Okno kuchnia', type: 1),
      ];
  });

  void size(WidgetTester tester, Size s, {double scale = 1.0}) {
    tester.view.physicalSize = s;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget shell({double scale = 1.0, Size? s}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
              size: s ?? phone, textScaler: TextScaler.linear(scale)),
          child: HomeShell(
            account: account,
            controller: session,
            scenes: ScenesController(),
            settings: AppSettings(),
            rooms: rooms,
            tuya: TuyaController(),
            viessmann: ViessmannController(),
            faults: testFaults(),
            household: household,
          ),
        ),
      );

  group('nawigacja', () {
    testWidgets('telefon ma dolny pasek, tablet panel z boku', (tester) async {
      size(tester, phone);
      await tester.pumpWidget(shell(s: phone));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      size(tester, tabletLandscape);
      await tester.pumpWidget(shell(s: tabletLandscape));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Planer'), findsOneWidget);
    });

    testWidgets('tablet w pionie (800 dp) też ma panel boczny', (tester) async {
      size(tester, tabletPortrait);
      await tester.pumpWidget(shell(s: tabletPortrait));
      await tester.pump(const Duration(seconds: 1));
      // 800 dp to jeszcze poniżej progu panelu: dolny pasek, ale kolumny w treści.
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('ekran Dom na tablecie', () {
    Future<void> pump(WidgetTester tester, Size s, {double scale = 1.0}) async {
      size(tester, s);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: s, textScaler: TextScaler.linear(scale)),
          child: HomeScreen(
            account: account,
            session: session,
            rooms: rooms,
            tuya: TuyaController(),
            viessmann: ViessmannController(),
            faults: testFaults(),
          ),
        ),
      ));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets(
        'pokoje stoją obok siebie w kilku kolumnach, na telefonie jeden pod drugim',
        (tester) async {
      await pump(tester, tabletLandscape);
      await tester.pump(const Duration(seconds: 2)); // kończy kaskadę FadeUp
      final salon = tester.getTopLeft(find.text('Salon'));
      final kitchen = tester.getTopLeft(find.text('Kuchnia'));
      final bedroom = tester.getTopLeft(find.text('Sypialnia'));
      expect(kitchen.dy, salon.dy, reason: 'drugi pokój w tym samym rzędzie');
      expect(kitchen.dx, greaterThan(salon.dx + 300));
      expect(bedroom.dy, salon.dy, reason: 'przy 1280 dp trzy kolumny');

      await pump(tester, phone);
      await tester.pump(const Duration(seconds: 2)); // kończy kaskadę FadeUp
      final p1 = tester.getTopLeft(find.text('Salon'));
      final p2 = tester.getTopLeft(find.text('Kuchnia'));
      expect(p2.dy, greaterThan(p1.dy + 20));
      expect(p2.dx, p1.dx);
    });

    testWidgets(
        'bez overflow na tablecie i na małym telefonie, skala tekstu 1.0 i 2.0',
        (tester) async {
      for (final s in [tabletPortrait, tabletLandscape, const Size(360, 640)]) {
        for (final scale in [1.0, 2.0]) {
          await pump(tester, s, scale: scale);
          for (final tab in ['Rolety', 'Oświetlenie']) {
            await tester.tap(find.byTooltip(tab));
            await tester.pump(const Duration(milliseconds: 600));
            await tester.pump(const Duration(seconds: 1));
          }
          expect(tester.takeException(), isNull,
              reason: '${s.width}×${s.height} skala $scale');
        }
      }
    });
  });

  group('planer na tablecie', () {
    Future<void> pumpPlanner(WidgetTester tester, Size s,
        {double scale = 1.0}) async {
      size(tester, s);
      household.bind('a');
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: s, textScaler: TextScaler.linear(scale)),
          child: Scaffold(
              body: PlannerScreen(household: household, account: account)),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('kalendarz: miesiąc po lewej, plan dnia po prawej',
        (tester) async {
      await pumpPlanner(tester, tabletLandscape);
      await tester.tap(find.text('Kalendarz'));
      await tester.pumpAndSettle();

      final month =
          tester.getCenter(find.textContaining('${DateTime.now().year}').first);
      final agenda = tester.getTopLeft(find.text('Nic tego dnia.'));
      expect(agenda.dx, greaterThan(month.dx),
          reason: 'plan dnia obok kalendarza');

      await pumpPlanner(tester, phone);
      await tester.tap(find.text('Kalendarz'));
      await tester.pumpAndSettle();
      final below = tester.getTopLeft(find.text('Nic tego dnia.'));
      expect(below.dx, lessThan(100),
          reason: 'na telefonie plan dnia pod siatką');
    });

    testWidgets(
        'zakładki bez overflow na tablecie i telefonie, skala 1.0 i 2.0',
        (tester) async {
      for (final s in [tabletPortrait, tabletLandscape, const Size(360, 640)]) {
        for (final scale in [1.0, 2.0]) {
          await pumpPlanner(tester, s, scale: scale);
          for (final tab in [
            'Zakupy',
            'Przypomnienia',
            'Kalendarz',
            'Wiadomości'
          ]) {
            await tester.tap(find.text(tab).first);
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull,
              reason: '${s.width}×${s.height} skala $scale');
        }
      }
    });
  });

  group('szerokość treści', () {
    testWidgets(
        'pushowany ekran ma na tablecie ograniczoną szerokość, na telefonie pełną',
        (tester) async {
      for (final (s, expected) in [(tabletLandscape, 640.0), (phone, 390.0)]) {
        size(tester, s);
        await tester.pumpWidget(
            const SizedBox()); // świeża aplikacja, bez trasy z poprzedniego obrotu
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(AppRoute(
                  builder: (_) => const Scaffold(
                      body: SizedBox.expand(key: Key('content'))),
                )),
                child: const Text('Otwórz'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('Otwórz'));
        await tester.pumpAndSettle();
        expect(
            tester.getSize(find.byKey(const Key('content'))).width, expected);
      }
    });
  });

  group('orientacja', () {
    final calls = <List<String>>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          calls.add((call.arguments as List).cast<String>());
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
    });

    testWidgets(
        'telefon jest zablokowany w pionie, tablet obraca się swobodnie',
        (tester) async {
      size(tester, phone);
      await tester.pumpWidget(
          const MaterialApp(home: OrientationPolicy(child: SizedBox())));
      expect(calls.last, ['DeviceOrientation.portraitUp']);

      size(tester, tabletLandscape);
      await tester.pumpWidget(const MaterialApp(
          home: OrientationPolicy(child: SizedBox(key: Key('t')))));
      await tester.pump();
      expect(calls.last.toSet(), {
        'DeviceOrientation.portraitUp',
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.portraitDown',
        'DeviceOrientation.landscapeRight',
      });
    });

    test('próg: krótszy bok poniżej 600 dp to telefon, także po obróceniu', () {
      expect(isPhone(const Size(390, 844)), isTrue);
      expect(isPhone(const Size(844, 390)), isTrue);
      expect(isPhone(const Size(800, 1280)), isFalse);
      expect(isPhone(const Size(600, 960)), isFalse);
    });
  });
}
