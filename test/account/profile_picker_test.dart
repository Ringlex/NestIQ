import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/profile_picker_screen.dart';

import 'fake_server.dart';

void main() {
  AccountController accountWith(List<Profile> profiles) => AccountController(
        api: NestIqApi(
            baseUrl: 'http://test', client: FakeServer((_) => null).client),
        store: MemoryStore(),
      )
        ..profiles = profiles
        ..phase = AccountPhase.choosingProfile;

  final profiles = [
    Profile.fromJson(profileJson('p1', 'Mama', hasPin: true)),
    Profile.fromJson(
        profileJson('p2', 'Bardzo długie imię domownika', role: 'member')),
    Profile.fromJson(profileJson('p3', 'Dziecko', role: 'restricted')),
    Profile.fromJson(profileJson('p4', 'Babcia', role: 'member', hasPin: true)),
  ];

  // Karta nie może się przepełniać przy większej czcionce systemowej ani na małym ekranie.
  for (final scale in [1.0, 1.3, 1.6, 2.0]) {
    testWidgets('karty profili mieszczą się przy skali tekstu $scale',
        (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
              size: const Size(360, 700), textScaler: TextScaler.linear(scale)),
          child: ProfilePickerScreen(account: accountWith(profiles)),
        ),
      ));
      await tester.pump(const Duration(seconds: 1));

      // Przepełnienie zgłaszane jest jako wyjątek rysowania i wywraca test.
      expect(tester.takeException(), isNull);
      expect(find.text('Mama'), findsOneWidget);
      expect(find.text('Dziecko', skipOffstage: false), findsOneWidget);
    });
  }
}
