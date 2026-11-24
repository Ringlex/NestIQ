import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/faults_screen.dart';
import 'package:nestiq/screens/home_shell.dart';
import 'package:nestiq/screens/viessmann_screen.dart';
import 'package:nestiq/state/app_settings.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/scenes_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/fault_service.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/viessmann/viessmann_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/fake_server.dart';
import 'faults_test.dart' show featuresWith, entry;
import 'fakes.dart';
import 'fakes_faults.dart';
import 'fixtures.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  late FakeViessmannApi api;

  Future<ViessmannController> controller(
      {List<Map<String, dynamic>>? data}) async {
    final c = ViessmannController(
      store: MemoryViessmannStore()
        ..saved = const StoredViessmann(
          clientId: '1561f44a5fbce8acf0c3cea9334e5af1',
          refreshToken: 'R',
          device: testDevice,
        ),
      apiFactory: ({required token, required onCall}) {
        api = FakeViessmannApi(onCall);
        if (data != null) api.data = data;
        return api;
      },
      minRefreshGap: Duration.zero,
      settleDelay: Duration.zero,
      isInForeground: () => true,
    );
    await c.load();
    addTearDown(c.dispose);
    return c;
  }

  void phone(WidgetTester tester) {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('ekran usterek', () {
    testWidgets('bez usterek mówi, że wszystko w porządku', (tester) async {
      phone(tester);
      await tester.pumpWidget(
          MaterialApp(home: FaultsScreen(viessmann: await controller())));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);

      expect(find.text('Brak usterek'), findsOneWidget);
    });

    testWidgets('pokazuje usterki z opisem: co się stało, co zrobić i kod',
        (tester) async {
      phone(tester);
      final data = featuresWith(
        lock: true,
        errors: [entry('F.1000', '2026-10-27T10:00:00.000Z')],
        service: [entry('A.2', '2026-10-26T08:00:00.000Z')],
        info: [entry('I.5', '2026-10-25T08:00:00.000Z')],
      );
      await tester.pumpWidget(MaterialApp(
          home: FaultsScreen(viessmann: await controller(data: data))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);

      expect(find.text('Blokada awaryjna pieca'), findsOneWidget);
      expect(find.text('Usterka pieca F.1000'), findsOneWidget);
      expect(find.text('Komunikat serwisowy A.2'), findsOneWidget);
      expect(find.text('Informacje'), findsOneWidget);
      expect(find.text('Komunikat pieca I.5'), findsOneWidget);
      expect(find.text('Co się stało'), findsWidgets);
      expect(find.text('Co zrobić'), findsWidgets);
      expect(find.textContaining('Piec zgłosił usterkę o kodzie F.1000'),
          findsOneWidget);
    });

    testWidgets('kod można skopiować', (tester) async {
      phone(tester);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData')
          copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final data =
          featuresWith(errors: [entry('F.1000', '2026-10-27T10:00:00.000Z')]);
      await tester.pumpWidget(MaterialApp(
          home: FaultsScreen(viessmann: await controller(data: data))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);

      await tester.tap(find.text('Kopiuj kod F.1000'));
      await settle(tester);

      expect(copied, ['F.1000']);
    });

    testWidgets('przy otwarciu odświeża dane z pieca', (tester) async {
      phone(tester);
      final v = await controller();
      await tester.pumpWidget(MaterialApp(home: FaultsScreen(viessmann: v)));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);

      expect(api.featureCalls, greaterThanOrEqualTo(1));
    });
  });

  group('powiadomienia w ustawieniach pieca', () {
    testWidgets('przełącznik prosi o zgodę i włącza powiadomienia',
        (tester) async {
      phone(tester);
      final store = MemoryFaultStore();
      final scheduler = RecordingScheduler();
      final faults = FaultService(
        store: store,
        notifier: RecordingNotifier(),
        scheduler: scheduler,
        requestPermission: () async => true,
      );
      final v = await controller();
      await v.refresh(force: true);
      await tester.pumpWidget(
          MaterialApp(home: ViessmannScreen(viessmann: v, faults: faults)));
      await settle(tester);

      await tester.tap(find.byType(Switch));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);

      expect(store.on, isTrue);
      expect(scheduler.starts, 1);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets(
        'odmowa zgody systemowej zostawia wyłączone i tłumaczy dlaczego',
        (tester) async {
      phone(tester);
      final store = MemoryFaultStore();
      final faults = FaultService(
        store: store,
        notifier: RecordingNotifier(),
        scheduler: RecordingScheduler(),
        requestPermission: () async => false,
      );
      final v = await controller();
      await v.refresh(force: true);
      await tester.pumpWidget(
          MaterialApp(home: ViessmannScreen(viessmann: v, faults: faults)));
      await settle(tester);

      await tester.tap(find.byType(Switch));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);

      expect(store.on, isFalse);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(
          find.textContaining('Brak zgody na powiadomienia'), findsOneWidget);
    });
  });

  group('dotknięcie powiadomienia', () {
    Future<void> pumpShell(WidgetTester tester,
        {required FaultService faults,
        required bool heating,
        required ViessmannController v}) async {
      phone(tester);
      final profile = Profile.fromJson({
        ...profileJson('p', 'Test', role: 'member'),
        'permissions': {
          'controlLights': true,
          'controlBlinds': true,
          'controlHeating': heating,
          'runScenes': true,
          'editScenes': false,
          'manageSettings': false,
        },
      });
      final account = AccountController(
        api: NestIqApi(
            baseUrl: 'http://test', client: FakeServer((_) => null).client),
        store: MemoryStore(),
      )
        ..active = profile
        ..phase = AccountPhase.active;
      await tester.pumpWidget(MaterialApp(
        home: HomeShell(
          account: account,
          controller: SessionController(),
          scenes: ScenesController(),
          settings: AppSettings(),
          rooms: RoomsController(),
          tuya: TuyaController(),
          viessmann: v,
          faults: faults,
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);
    }

    testWidgets('zimny start z powiadomienia otwiera ekran usterek',
        (tester) async {
      final faults = FaultService(
        store: MemoryFaultStore(),
        notifier: RecordingNotifier(),
        launchedFromNotification: true,
      );
      final v = await controller(data: featuresWith(lock: true));

      await pumpShell(tester, faults: faults, heating: true, v: v);

      expect(find.byType(FaultsScreen), findsOneWidget);
      expect(find.text('Blokada awaryjna pieca'), findsOneWidget);
      expect(faults.pendingOpen, isFalse);
    });

    testWidgets(
        'dotknięcie, gdy aplikacja już działa, też otwiera ekran usterek',
        (tester) async {
      final faults = FaultService(
          store: MemoryFaultStore(), notifier: RecordingNotifier());
      final v = await controller(
          data:
              featuresWith(errors: [entry('F.9', '2026-10-27T10:00:00.000Z')]));
      await pumpShell(tester, faults: faults, heating: true, v: v);
      expect(find.byType(FaultsScreen), findsNothing);

      faults.pendingOpen = true;
      faults
          .consumeOpenRequest(); // symulacja: zdarzenie przeszło przez kolejkę
      faults.pendingOpen = true;
      // ignore: invalid_use_of_protected_member
      faults.notifyListeners();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);

      expect(find.byType(FaultsScreen), findsOneWidget);
      expect(find.text('Usterka pieca F.9'), findsOneWidget);
    });

    testWidgets('profil bez prawa do ogrzewania nie dostaje ekranu usterek',
        (tester) async {
      final faults = FaultService(
        store: MemoryFaultStore(),
        notifier: RecordingNotifier(),
        launchedFromNotification: true,
      );
      final v = await controller(data: featuresWith(lock: true));

      await pumpShell(tester, faults: faults, heating: false, v: v);

      expect(find.byType(FaultsScreen), findsNothing);
      expect(faults.pendingOpen, isFalse,
          reason: 'prośba jest zużyta, nie wisi w nieskończoność');
    });
  });
}
