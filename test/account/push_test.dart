import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/notifications/push_service.dart';

import 'fake_server.dart';

class FakePush extends NoPushService {
  FakePush(this.value);

  String? value;
  final refreshes = StreamController<String>.broadcast();

  @override
  Future<String?> token() async => value;

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;
}

void main() {
  FakeServer serverWith(List<Map<String, dynamic>> pushes,
      {int pushStatus = 200}) {
    return FakeServer((r) {
      switch ('${r.method} ${r.url.path}') {
        case 'POST /v1/auth/login':
          return (200, sessionJson('anna@wp.pl'));
        case 'GET /v1/profiles':
          return (
            200,
            {
              'profiles': [profileJson('p1', 'Anna')]
            }
          );
        case 'POST /v1/push/register':
          pushes.add(jsonDecode(r.body) as Map<String, dynamic>);
          return (pushStatus, {'status': 'ok'});
      }
      return null;
    });
  }

  AccountController build(FakeServer server, PushService push) =>
      AccountController(
        api: NestIqApi(baseUrl: 'http://test', client: server.client),
        store: MemoryStore(),
        push: push,
      );

  test('po zalogowaniu token urządzenia trafia na serwer', () async {
    final pushes = <Map<String, dynamic>>[];
    final account = build(serverWith(pushes), FakePush('t' * 40));

    await account.login('anna@wp.pl', 'haslo12345');
    await Future<void>.delayed(Duration.zero);

    expect(pushes, [
      {'token': 't' * 40, 'platform': 'android'}
    ]);
  });

  test('nowy token od Firebase jest przekazywany, gdy sesja trwa', () async {
    final pushes = <Map<String, dynamic>>[];
    final push = FakePush(null);
    final account = build(serverWith(pushes), push);

    push.refreshes.add('x' * 40);
    await Future<void>.delayed(Duration.zero);
    expect(pushes, isEmpty, reason: 'bez sesji nie ma komu go przypisać');

    await account.login('anna@wp.pl', 'haslo12345');
    push.refreshes.add('y' * 40);
    await Future<void>.delayed(Duration.zero);

    expect(pushes.map((p) => p['token']), ['y' * 40]);
  });

  test('brak push albo błąd serwera nie psuje logowania', () async {
    final none = build(serverWith([]), const NoPushService());
    await none.login('anna@wp.pl', 'haslo12345');
    expect(none.phase, isNot(AccountPhase.signedOut));

    final failing = build(serverWith([], pushStatus: 500), FakePush('t' * 40));
    await failing.login('anna@wp.pl', 'haslo12345');
    await Future<void>.delayed(Duration.zero);
    expect(failing.phase, isNot(AccountPhase.signedOut));
  });
}
