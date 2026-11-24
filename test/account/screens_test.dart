import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/auth_screen.dart';
import 'package:nestiq/screens/home_shell.dart';
import 'package:nestiq/screens/pin_screen.dart';
import 'package:nestiq/state/app_settings.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/scenes_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';

import 'fake_server.dart';
import '../viessmann/fakes_faults.dart';

AccountController accountFor(FakeServer server) => AccountController(
      api: NestIqApi(baseUrl: 'http://test', client: server.client),
      store: MemoryStore(),
    );

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Profile profile(String role) =>
    Profile.fromJson(profileJson('p', 'Test', role: role));

void main() {
  group('logowanie', () {
    testWidgets('niepoprawny e-mail jest zatrzymany przed wysłaniem do serwera',
        (tester) async {
      phone(tester);
      final server = FakeServer((_) => null);
      await tester.pumpWidget(
          MaterialApp(home: AuthScreen(account: accountFor(server))));
      await tester.pump(const Duration(seconds: 1));

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Adres e-mail'), 'anna.wp.pl');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Hasło'), 'haslo12345');
      await tester.tap(find.widgetWithText(FilledButton, 'Zaloguj się'));
      await tester.pump();

      expect(find.text('Podaj poprawny adres e-mail, np. anna@wp.pl.'),
          findsOneWidget);
      expect(server.log, isEmpty);
    });

    testWidgets('rejestracja pilnuje zgodności haseł', (tester) async {
      phone(tester);
      final server = FakeServer((_) => null);
      await tester.pumpWidget(
          MaterialApp(home: AuthScreen(account: accountFor(server))));
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.text('Zarejestruj się'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Adres e-mail'), 'anna@wp.pl');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Hasło'), 'haslo12345');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Powtórz hasło'), 'inne-haslo');
      await tester.tap(find.widgetWithText(FilledButton, 'Utwórz konto'));
      await tester.pump();

      expect(find.text('Hasła nie są takie same.'), findsOneWidget);
      expect(server.log, isEmpty);
    });

    testWidgets('błąd serwera pokazuje się jako czytelny komunikat',
        (tester) async {
      phone(tester);
      final server = FakeServer((_) => (401, {'error': 'invalid_credentials'}));
      await tester.pumpWidget(
          MaterialApp(home: AuthScreen(account: accountFor(server))));
      await tester.pump(const Duration(seconds: 1));

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Adres e-mail'), 'anna@wp.pl');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Hasło'), 'haslo12345');
      await tester.tap(find.widgetWithText(FilledButton, 'Zaloguj się'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Nieprawidłowy e-mail lub hasło.'), findsOneWidget);
    });
  });

  group('PIN', () {
    testWidgets('zły PIN pokazuje komunikat i czyści kropki', (tester) async {
      phone(tester);
      final server = FakeServer((r) => (401, {'error': 'invalid_pin'}));
      final account = accountFor(server);
      await tester.pumpWidget(MaterialApp(
        home: PinScreen(
            account: account,
            profile: Profile.fromJson(profileJson('p1', 'Mama', hasPin: true))),
      ));
      await tester.pump(const Duration(seconds: 1));

      for (final digit in ['1', '2', '3', '4']) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Nieprawidłowy PIN.'), findsOneWidget);
      expect(server.log, ['POST /v1/profiles/p1/select']);
      expect(account.phase, AccountPhase.restoring); // nic nie wybrano
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
        'po blokadzie klawiatura jest nieaktywna i jest wskazówka o administratorze',
        (tester) async {
      phone(tester);
      final server = FakeServer((r) => (
            429,
            {
              'error': 'locked',
              'retryAt': DateTime.now()
                  .add(const Duration(minutes: 15))
                  .toUtc()
                  .toIso8601String()
            },
          ));
      await tester.pumpWidget(MaterialApp(
        home: PinScreen(
          account: accountFor(server),
          profile: Profile.fromJson(profileJson('p1', 'Mama', hasPin: true)),
        ),
      ));
      await tester.pump(const Duration(seconds: 1));

      for (final digit in ['1', '2', '3', '4']) {
        await tester.tap(find.widgetWithText(FilledButton, digit));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.textContaining('poproś administratora'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '5'))
              .onPressed,
          isNull);
    });
  });

  group('nawigacja zależna od uprawnień', () {
    Future<void> pumpShell(WidgetTester tester, Profile active) async {
      phone(tester);
      final account = accountFor(FakeServer((_) => null))
        ..active = active
        ..phase = AccountPhase.active;
      await tester.pumpWidget(MaterialApp(
        home: HomeShell(
          account: account,
          controller: SessionController(),
          scenes: ScenesController(),
          settings: AppSettings(),
          rooms: RoomsController(),
          tuya: TuyaController(),
          viessmann: ViessmannController(),
          faults: testFaults(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));
    }

    List<String> labels(WidgetTester tester) => tester
        .widgetList<NavigationDestination>(find.byType(NavigationDestination))
        .map((d) => d.label)
        .toList();

    testWidgets('administrator widzi Sceny i Ustawienia', (tester) async {
      await pumpShell(tester, profile('admin'));
      expect(labels(tester), ['Dom', 'Sceny', 'Profil', 'Ustawienia']);
    });

    testWidgets('Dziecko nie widzi ani Scen, ani Ustawień', (tester) async {
      await pumpShell(tester, profile('restricted'));
      expect(labels(tester), ['Dom', 'Profil']);
    });

    testWidgets('domownik widzi Sceny, ale nie Ustawienia', (tester) async {
      await pumpShell(tester, profile('member'));
      expect(labels(tester), ['Dom', 'Sceny', 'Profil']);
    });
  });
}
