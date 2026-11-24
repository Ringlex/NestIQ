// Test na żywo: klient Fluttera przeciwko prawdziwemu backendowi (backend/).
//   cd backend && npx wrangler d1 migrations apply nestiq --local
//   npx wrangler dev --port 8799 > /tmp/nestiq-dev.log 2>&1 &
//   flutter test test/integration/backend_live_test.dart \
//     --dart-define=NESTIQ_API=http://127.0.0.1:8799 \
//     --dart-define=NESTIQ_DEV_LOG=/tmp/nestiq-dev.log
// Kody z maila czytamy z logu `wrangler dev` (DEV_LOG_MAIL=true w .dev.vars).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';

import '../account/fake_server.dart';

const logPath = String.fromEnvironment('NESTIQ_DEV_LOG');
const apiUrl = String.fromEnvironment('NESTIQ_API');

String lastCode(String marker) {
  final matches =
      RegExp('(\\d{6}) - $marker').allMatches(File(logPath).readAsStringSync());
  return matches.last.group(1)!;
}

void main() {
  // `flutter test` podmienia HttpClient na atrapę zwracającą 400 – tu chcemy prawdziwą sieć.
  setUpAll(() => HttpOverrides.global = null);

  test('rejestracja, kod, profile, PIN, blokada i reset przez admina',
      () async {
    final email = 'test${DateTime.now().millisecondsSinceEpoch}@wp.pl';
    final store = MemoryStore();
    final account = AccountController(api: NestIqApi(), store: store);

    await account.register(email, 'haslo12345');
    expect(account.phase, AccountPhase.awaitingVerification);

    await expectLater(
        account.verify('000000'),
        throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'invalid_code')));

    await account.verify(lastCode('kod potwierdzajacy'));
    expect(account.phase, AccountPhase.needsProfile);

    await account.createFirstProfile(
        name: 'Mama', color: '#B9EBF3', pin: '1234');
    expect(account.phase, AccountPhase.active);
    expect(account.isAdmin, isTrue);

    final child = await account.createProfile(
      name: 'Dziecko',
      color: '#D9E3F8',
      role: ProfileRole.restricted,
      permissions: Permissions.preset(ProfileRole.restricted),
      pin: '4321',
    );
    expect(child.permissions.editScenes, isFalse);
    expect(account.profiles, hasLength(2));

    // Nowa instalacja: zalogowanie i wybór profilu z PIN-em.
    final other = AccountController(api: NestIqApi(), store: MemoryStore());
    await other.login(email, 'haslo12345');
    expect(other.phase, AccountPhase.choosingProfile);
    await expectLater(
        other.selectProfile(child.id, pin: '0000'),
        throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'invalid_pin')));
    await other.selectProfile(child.id, pin: '4321');
    expect(other.active?.name, 'Dziecko');
    expect(other.isAdmin, isFalse);

    // Dziecko nie zarządza profilami.
    await expectLater(
        other.setPin(child.id, null),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'admin_required')));

    // Admin resetuje PIN dziecka, które wchodzi bez kodu.
    await account.setPin(child.id, null);
    await other.selectProfile(child.id);

    // Ostatniego administratora nie da się usunąć.
    await expectLater(
        account.deleteProfile(account.active!.id),
        throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'last_admin')));

    // Odświeżenie sesji po zapisanym tokenie.
    final restarted = AccountController(api: NestIqApi(), store: store);
    await restarted.restore();
    expect(restarted.phase, AccountPhase.choosingProfile); // Mama ma PIN

    await account.logout();
    expect(account.phase, AccountPhase.signedOut);
  },
      skip: apiUrl.isEmpty || logPath.isEmpty
          ? 'Podaj NESTIQ_API i NESTIQ_DEV_LOG (patrz nagłówek)'
          : false);
}
