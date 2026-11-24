import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/auth_screen.dart';
import 'package:nestiq/screens/forgot_password_screen.dart';
import 'package:nestiq/screens/home_shell.dart';
import 'package:nestiq/screens/pin_screen.dart';
import 'package:nestiq/screens/profile_form_screen.dart';
import 'package:nestiq/screens/profiles_screen.dart';
import 'package:nestiq/screens/rooms_screen.dart';
import 'package:nestiq/screens/settings_screen.dart';
import 'package:nestiq/screens/tuya_screen.dart';
import 'package:nestiq/screens/user_screen.dart';
import 'package:nestiq/screens/faults_screen.dart';
import 'package:nestiq/screens/heating_detail_screens.dart';
import 'package:nestiq/screens/heating_view.dart';
import 'package:nestiq/screens/verify_email_screen.dart';
import 'package:nestiq/screens/viessmann_screen.dart';
import 'package:nestiq/state/app_settings.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/scenes_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/tuya/tuya_models.dart';

import '../tuya/fakes.dart';
import '../viessmann/fakes_faults.dart';
import '../viessmann/fakes.dart';
import '../viessmann/faults_test.dart' show featuresWith, entry;
import '../viessmann/fixtures.dart';
import 'package:nestiq/viessmann/viessmann_store.dart';
import 'fake_server.dart';

/// Przegląd ekranów na małym telefonie (360×640) przy powiększonej czcionce systemowej:
/// żaden nie może zgłosić przepełnienia.
void main() {
  final server = FakeServer((_) => null);
  AccountController account({String role = 'admin'}) => AccountController(
        api: NestIqApi(baseUrl: 'http://test', client: server.client),
        store: MemoryStore(),
      )
        ..email = 'anna.kowalska@bardzo-dluga-domena-pocztowa.pl'
        ..pendingEmail = 'anna.kowalska@bardzo-dluga-domena-pocztowa.pl'
        ..profiles = [
          Profile.fromJson(profileJson('a', 'Mama', role: role, hasPin: true))
        ]
        ..active =
            Profile.fromJson(profileJson('a', 'Mama', role: role, hasPin: true))
        ..phase = AccountPhase.active;

  final rooms = RoomsController();

  TuyaController tuya() {
    final t = TuyaController(store: MemoryTuyaStore());
    t.devices = const [
      TuyaDevice(
          id: 'dev1',
          name: 'Bardzo długa nazwa włącznika w salonie',
          localKey: '0123456789abcdef',
          channels: [
            TuyaChannel(dpId: 1, code: 'switch_1', name: 'Przycisk 1'),
            TuyaChannel(dpId: 2, code: 'switch_2', name: 'Przycisk 2'),
          ]),
    ];
    t.credentials = const TuyaCloudCredentials(
        accessId: 'abcd1234efgh5678', accessSecret: 'secret');
    return t;
  }

  ViessmannController heating() {
    final c = ViessmannController(
      store: MemoryViessmannStore()
        ..saved = const StoredViessmann(
            clientId: '1561f44a5fbce8acf0c3cea9334e5af1',
            refreshToken: 'R',
            device: testDevice),
      apiFactory: ({required token, required onCall}) =>
          FakeViessmannApi(onCall),
      minRefreshGap: Duration.zero,
    );
    return c;
  }

  final screens = <String, Widget Function()>{
    'Viessmann (połączenie)': () =>
        ViessmannScreen(viessmann: heating(), faults: testFaults()),
    'logowanie': () => AuthScreen(account: account()),
    'weryfikacja e-mail': () => VerifyEmailScreen(account: account()),
    'reset hasła': () => ForgotPasswordScreen(account: account()),
    'PIN': () => PinScreen(
        account: account(),
        profile: Profile.fromJson(
            profileJson('a', 'Mama z długim imieniem', hasPin: true))),
    'pierwszy profil': () =>
        ProfileFormScreen.first(account: account(), rooms: rooms),
    'nowy profil': () =>
        ProfileFormScreen.create(account: account(), rooms: rooms),
    'lista profili': () => ProfilesScreen(account: account(), rooms: rooms),
    'pokoje': () =>
        RoomsScreen(rooms: rooms, session: SessionController(), tuya: tuya()),
    'Tuya': () => TuyaScreen(tuya: tuya(), rooms: rooms),
    'profil (zakładka)': () => UserScreen(
        account: account(), session: SessionController(), rooms: rooms),
    'ustawienia': () => SettingsScreen(
          settings: AppSettings(),
          account: account(),
          session: SessionController(),
          rooms: rooms,
          tuya: tuya(),
          viessmann: ViessmannController(),
          faults: testFaults(),
        ),
    'dom (cała powłoka)': () => HomeShell(
          account: account(),
          controller: SessionController(),
          scenes: ScenesController(),
          settings: AppSettings(),
          rooms: rooms,
          tuya: tuya(),
          viessmann: ViessmannController(),
          faults: testFaults(),
        ),
  };

  for (final scale in [1.0, 2.0]) {
    for (final entry in screens.entries) {
      testWidgets('${entry.key} bez przepełnienia przy skali tekstu $scale',
          (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: entry.value(),
        ));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 500));

        expect(tester.takeException(), isNull);
        // Zatrzymanie timerów (heartbeat, odliczanie), żeby test mógł się zakończyć.
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  // Ekran usterek z kompletem zdarzeń (blokada, usterka, serwis, informacja).
  for (final scale in [1.0, 2.0]) {
    testWidgets('ekran usterek bez przepełnienia przy skali tekstu $scale',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final c = ViessmannController(
        store: MemoryViessmannStore()
          ..saved = const StoredViessmann(
              clientId: '1561f44a5fbce8acf0c3cea9334e5af1',
              refreshToken: 'R',
              device: testDevice),
        apiFactory: ({required token, required onCall}) =>
            FakeViessmannApi(onCall)
              ..data = featuresWith(
                lock: true,
                errors: [entry('F.1000', '2026-10-27T10:00:00.000Z')],
                service: [entry('A.2', '2026-10-26T08:00:00.000Z')],
                info: [entry('I.5', '2026-10-25T08:00:00.000Z')],
              ),
        minRefreshGap: Duration.zero,
        settleDelay: Duration.zero,
        isInForeground: () => true,
      );
      await c.load();
      await c.refresh(force: true);

      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: FaultsScreen(viessmann: c),
      ));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      expect(find.text('Blokada awaryjna pieca'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  // Ekrany szczegółów (edytor temperatury) z prawdziwym odczytem.
  for (final scale in [1.0, 2.0]) {
    for (final name in ['Ciepła woda', 'Ogrzewanie']) {
      testWidgets('ekran „$name” bez przepełnienia przy skali tekstu $scale',
          (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final c = heating();
        await c.load();
        await c.refresh(force: true);

        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: name == 'Ciepła woda'
              ? HotWaterScreen(viessmann: c, canControl: true)
              : HeatingCircuitScreen(viessmann: c, canControl: true),
        ));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 500));
        // Niezapisana zmiana pokazuje dodatkowy wiersz z przyciskiem.
        await tester.tap(find.byTooltip('Więcej'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump(const Duration(milliseconds: 700));

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  // Karty ogrzewania z prawdziwym odczytem (długie wartości, wszystkie sekcje).
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'ogrzewanie (karty z odczytem) bez przepełnienia przy skali tekstu $scale',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final c = heating();
      await c.load();
      await c.refresh(force: true);
      expect(c.state, isNotNull);

      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: HeatingView(
              viessmann: c, canControl: true, canManage: true, onSetup: () {}),
        ),
      ));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      expect(find.text('Ciepła woda'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
