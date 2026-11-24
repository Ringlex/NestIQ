import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/account_store.dart';
import 'package:nestiq/account/nestiq_api.dart';

import 'fake_server.dart';

AccountController build(FakeServer server, [MemoryStore? store]) =>
    AccountController(
      api: NestIqApi(baseUrl: 'http://test', client: server.client),
      store: store ?? MemoryStore(),
    );

void main() {
  group('rejestracja i pierwszy profil', () {
    test('konto -> kod -> pierwszy profil administratora', () async {
      final profiles = <Map<String, dynamic>>[];
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'POST /v1/auth/register':
            return (200, {'status': 'verification_required'});
          case 'POST /v1/auth/verify':
            return (200, sessionJson('anna@wp.pl'));
          case 'GET /v1/profiles':
            return (200, {'profiles': profiles});
          case 'POST /v1/profiles':
            profiles.add(profileJson('p1', 'Anna'));
            return (201, {'profile': profiles.first, 'accessToken': 'bound'});
        }
        return null;
      });
      final store = MemoryStore();
      final account = build(server, store);

      await account.register('anna@wp.pl', 'haslo12345');
      expect(account.phase, AccountPhase.awaitingVerification);
      expect(account.pendingEmail, 'anna@wp.pl');

      await account.verify('123456');
      expect(account.phase, AccountPhase.needsProfile);
      expect(store.saved.refreshToken, 'refresh-1');

      await account.createFirstProfile(name: 'Anna', color: '#B9EBF3');
      expect(account.phase, AccountPhase.active);
      expect(account.isAdmin, isTrue);
      expect(account.permissions.manageSettings, isTrue);
      expect(account.api.accessToken, 'bound');
      expect(store.saved.lastProfileId, 'p1');
    });

    test(
        'logowanie niepotwierdzonego konta wysyła kod i przechodzi do jego wpisania',
        () async {
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'POST /v1/auth/login':
            return (403, {'error': 'email_not_verified'});
          case 'POST /v1/auth/resend':
            return (200, {'status': 'ok'});
        }
        return null;
      });
      final account = build(server);

      await account.login('anna@wp.pl', 'haslo12345');

      expect(account.phase, AccountPhase.awaitingVerification);
      expect(server.log, contains('POST /v1/auth/resend'));
    });

    test('złe hasło rzuca błąd z czytelnym komunikatem', () async {
      final server = FakeServer((r) => (401, {'error': 'invalid_credentials'}));
      final account = build(server);

      await expectLater(
        account.login('anna@wp.pl', 'zle'),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('Nieprawidłowy'))),
      );
      expect(account.phase,
          AccountPhase.restoring); // stan nie zmieniony przez błąd
    });
  });

  group('wybór profilu', () {
    FakeServer serverWithProfiles({bool pinOk = true}) => FakeServer((r) {
          switch ('${r.method} ${r.url.path}') {
            case 'POST /v1/auth/login':
              return (200, sessionJson('anna@wp.pl'));
            case 'GET /v1/profiles':
              return (
                200,
                {
                  'profiles': [
                    profileJson('p1', 'Mama', hasPin: true),
                    profileJson('p2', 'Dziecko', role: 'restricted'),
                  ],
                }
              );
            case 'POST /v1/profiles/p1/select':
              return pinOk
                  ? (
                      200,
                      {
                        'profile': profileJson('p1', 'Mama', hasPin: true),
                        'accessToken': 'a2'
                      }
                    )
                  : (401, {'error': 'invalid_pin'});
            case 'POST /v1/profiles/p2/select':
              return (
                200,
                {
                  'profile': profileJson('p2', 'Dziecko', role: 'restricted'),
                  'accessToken': 'a3',
                }
              );
          }
          return null;
        });

    test('po zalogowaniu trzeba wybrać profil; zły PIN go nie wybiera',
        () async {
      final account = build(serverWithProfiles(pinOk: false));
      await account.login('anna@wp.pl', 'haslo12345');
      expect(account.phase, AccountPhase.choosingProfile);

      await expectLater(
          account.selectProfile('p1', pin: '0000'),
          throwsA(isA<ApiException>()
              .having((e) => e.code, 'code', 'invalid_pin')));
      expect(account.phase, AccountPhase.choosingProfile);
      expect(account.active, isNull);
    });

    test('profil Dziecko nie ma uprawnień do scen i ustawień', () async {
      final account = build(serverWithProfiles());
      await account.login('anna@wp.pl', 'haslo12345');
      await account.selectProfile('p2');

      expect(account.phase, AccountPhase.active);
      expect(account.permissions.controlLights, isTrue);
      expect(account.permissions.controlBlinds, isTrue);
      expect(account.permissions.runScenes, isFalse);
      expect(account.permissions.editScenes, isFalse);
      expect(account.permissions.manageSettings, isFalse);
      expect(account.isAdmin, isFalse);
    });

    test('ponowne uruchomienie wraca do ostatniego profilu bez PIN-u',
        () async {
      final store = MemoryStore()
        ..saved = const StoredAccount(
            refreshToken: 'r0', email: 'anna@wp.pl', lastProfileId: 'p2');
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'POST /v1/auth/refresh':
            return (200, sessionJson('anna@wp.pl', refresh: 'r1'));
          case 'GET /v1/profiles':
            return (
              200,
              {
                'profiles': [
                  profileJson('p1', 'Mama', hasPin: true),
                  profileJson('p2', 'Dziecko', role: 'restricted')
                ],
              }
            );
          case 'POST /v1/profiles/p2/select':
            return (
              200,
              {
                'profile': profileJson('p2', 'Dziecko', role: 'restricted'),
                'accessToken': 'a'
              }
            );
        }
        return null;
      });
      final account = build(server, store);

      await account.restore();

      expect(account.phase, AccountPhase.active);
      expect(account.active?.name, 'Dziecko');
      expect(store.saved.refreshToken, 'r1');
    });

    test('ostatni profil z PIN-em wymaga wyboru, a nie wchodzi sam', () async {
      final store = MemoryStore()
        ..saved = const StoredAccount(refreshToken: 'r0', lastProfileId: 'p1');
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'POST /v1/auth/refresh':
            return (200, sessionJson('anna@wp.pl'));
          case 'GET /v1/profiles':
            return (
              200,
              {
                'profiles': [profileJson('p1', 'Mama', hasPin: true)]
              }
            );
        }
        return null;
      });
      final restored = build(server, store);

      await restored.restore();

      expect(restored.phase, AccountPhase.choosingProfile);
      expect(server.log, isNot(contains('POST /v1/profiles/p1/select')));
    });
  });

  group('sesja', () {
    test('wygasły token dostępu jest odświeżany, a żądanie powtórzone raz',
        () async {
      var listCalls = 0;
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'GET /v1/profiles':
            listCalls++;
            // Pierwsze wywołanie ze starym tokenem odrzucone, drugie z nowym przechodzi.
            return r.headers['authorization'] == 'Bearer fresh'
                ? (
                    200,
                    {
                      'profiles': [profileJson('p1', 'Mama')]
                    }
                  )
                : (401, {'error': 'unauthorized'});
          case 'POST /v1/auth/refresh':
            return (
              200,
              sessionJson('anna@wp.pl', access: 'fresh', refresh: 'r2')
            );
        }
        return null;
      });
      final api = NestIqApi(baseUrl: 'http://test', client: server.client)
        ..accessToken = 'stale'
        ..refreshToken = 'r1';

      final profiles = await api.listProfiles();

      expect(profiles.single.name, 'Mama');
      expect(listCalls, 2);
      expect(api.refreshToken, 'r2');
    });

    test('równoległe żądania po wygaśnięciu czekają na jedną wymianę tokenu',
        () async {
      var refreshCalls = 0;
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'GET /v1/profiles':
            return r.headers['authorization'] == 'Bearer fresh'
                ? (200, {'profiles': <Object>[]})
                : (401, {'error': 'unauthorized'});
          case 'POST /v1/auth/refresh':
            refreshCalls++;
            return (
              200,
              sessionJson('anna@wp.pl', access: 'fresh', refresh: 'r2')
            );
        }
        return null;
      });
      final api = NestIqApi(baseUrl: 'http://test', client: server.client)
        ..accessToken = 'stale'
        ..refreshToken = 'r1';

      await Future.wait(
          [api.listProfiles(), api.listProfiles(), api.listProfiles()]);

      expect(refreshCalls, 1);
    });

    test('odrzucony token odświeżający wylogowuje', () async {
      final store = MemoryStore()
        ..saved = const StoredAccount(refreshToken: 'dead');
      final server =
          FakeServer((r) => (401, {'error': 'invalid_refresh_token'}));
      final account = build(server, store);

      await account.restore();

      expect(account.phase, AccountPhase.signedOut);
      expect(store.saved.refreshToken, isNull);
    });

    test(
        'brak sieci przy starcie to tryb offline, a sesja zostaje na telefonie',
        () async {
      final store = MemoryStore()
        ..saved = const StoredAccount(refreshToken: 'r1');
      final account = AccountController(
        api: NestIqApi(
          baseUrl: 'http://test',
          client: MockClient(
              (_) async => throw const SocketException('brak sieci')),
        ),
        store: store,
      );

      await account.restore();

      expect(account.phase, AccountPhase.offline);
      expect(store.saved.refreshToken, 'r1');
    });

    test('bez zapisanej sesji start kończy się ekranem logowania', () async {
      final account = build(FakeServer((_) => null));

      await account.restore();

      expect(account.phase, AccountPhase.signedOut);
    });

    test('wylogowanie czyści tokeny i profile', () async {
      final store = MemoryStore();
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'POST /v1/auth/login':
            return (200, sessionJson('anna@wp.pl'));
          case 'GET /v1/profiles':
            return (
              200,
              {
                'profiles': [profileJson('p1', 'Mama')]
              }
            );
          case 'POST /v1/auth/sign-out':
            return (200, {'status': 'ok'});
        }
        return null;
      });
      final account = build(server, store);
      await account.login('anna@wp.pl', 'haslo12345');

      await account.logout();

      expect(account.phase, AccountPhase.signedOut);
      expect(account.profiles, isEmpty);
      expect(account.api.refreshToken, isNull);
      expect(store.saved.refreshToken, isNull);
      expect(store.saved.email, 'anna@wp.pl'); // do wypełnienia formularza
    });
  });

  group('zarządzanie profilami', () {
    test('reset PIN-u przez administratora wysyła pin: null', () async {
      final server = FakeServer((r) {
        switch ('${r.method} ${r.url.path}') {
          case 'PUT /v1/profiles/p2/pin':
            return (200, {'status': 'ok'});
          case 'GET /v1/profiles':
            return (
              200,
              {
                'profiles': [profileJson('p2', 'Dziecko', role: 'restricted')]
              }
            );
        }
        return null;
      });
      final account = build(server);

      await account.setPin('p2', null);

      final request = server.requests.firstWhere((r) => r.method == 'PUT');
      expect(request.body, '{"pin":null}');
      expect(account.profiles.single.hasPin, isFalse);
    });

    test('blokada po serii pomyłek podaje, ile czekać', () {
      final error = ApiException(429, 'locked',
          retryAt:
              DateTime.now().add(const Duration(minutes: 14, seconds: 30)));
      expect(error.message, contains('15 min'));
    });
  });

  group('uprawnienia', () {
    test('presety ról zgadzają się z serwerem', () {
      final restricted = Permissions.preset(ProfileRole.restricted);
      expect(restricted.controlLights && restricted.controlBlinds, isTrue);
      expect(
          restricted.runScenes ||
              restricted.editScenes ||
              restricted.manageSettings,
          isFalse);

      final member = Permissions.preset(ProfileRole.member);
      expect(member.runScenes, isTrue);
      expect(member.editScenes || member.manageSettings, isFalse);

      expect(Permissions.preset(ProfileRole.admin).manageSettings, isTrue);
    });

    test(
        'profile sprzed dodania ogrzewania dostają domyślną wartość swojej roli',
        () {
      Permissions legacy(String role) => Profile.fromJson({
            ...profileJson('p', 'X', role: role),
            'permissions': {
              'controlLights': true,
              'controlBlinds': true,
              'runScenes': false,
              'editScenes': false,
              'manageSettings': false
            },
          }).permissions;

      expect(legacy('admin').controlHeating, isTrue);
      expect(legacy('member').controlHeating, isTrue);
      expect(legacy('restricted').controlHeating, isFalse);
    });

    test(
        'jawne uprawnienie do ogrzewania z serwera ma pierwszeństwo przed domyślnym',
        () {
      final p = Profile.fromJson({
        ...profileJson('p', 'X', role: 'member'),
        'permissions': {
          'controlLights': true,
          'controlBlinds': true,
          'controlHeating': false,
          'runScenes': true,
          'editScenes': false,
          'manageSettings': false
        },
      });
      expect(p.permissions.controlHeating, isFalse);
      expect(
          Permissions.preset(ProfileRole.restricted).controlHeating, isFalse);
      expect(
          Permissions.preset(ProfileRole.member)
              .copyWith(controlHeating: false)
              .toJson()['controlHeating'],
          isFalse);
    });

    test('kolor awatara dobiera czytelny kolor litery', () {
      expect(
          Profile.foregroundFor(Profile.parseColor('#FFE3A8'))
              .computeLuminance(),
          lessThan(0.2));
      expect(
          Profile.foregroundFor(Profile.parseColor('#10260A'))
              .computeLuminance(),
          greaterThan(0.8));
    });
  });
}
