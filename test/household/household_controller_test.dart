import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/household/household_controller.dart';
import 'package:nestiq/household/household_models.dart';

import '../account/fake_server.dart';

Map<String, dynamic> listJson(
        {List<Map<String, dynamic>> items = const [],
        List<String> shared = const []}) =>
    {
      'id': 'L1',
      'name': 'Spożywcze',
      'ownerProfileId': 'me',
      'sharedWith': shared,
      'items': items,
    };

Map<String, dynamic> itemJson(String id, String text, {bool checked = false}) =>
    {
      'id': id,
      'text': text,
      'quantity': null,
      'checked': checked,
      'checkedBy': null,
      'addedBy': 'me',
      'position': 1
    };

Map<String, dynamic> messageJson(String id, String from,
        {bool read = false, String? to}) =>
    {
      'id': id,
      'from': from,
      'to': to,
      'body': 'Treść $id',
      'createdAt': '2026-10-27T10:00:00.000Z',
      'read': read,
    };

/// Czeka na warunek zamiast stałego opóźnienia: pierwszy test w pliku bywa wolniejszy.
Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeServer server;
  late List<Map<String, dynamic>> lists;
  late List<Map<String, dynamic>> messages;
  late List<Map<String, dynamic>> reminders;
  var failPatch = false;

  HouseholdController build({
    void Function(List<PlannerMessage>)? onNew,
    void Function(List<Reminder>)? onReminders,
  }) {
    final api = NestIqApi(baseUrl: 'http://test', client: server.client)
      ..accessToken = 'tok';
    final c = HouseholdController(
      api: api,
      pollInterval: const Duration(milliseconds: 40),
      onNewMessages: onNew,
      onRemindersChanged: onReminders,
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    failPatch = false;
    lists = [
      listJson(items: [itemJson('I1', 'Mleko'), itemJson('I2', 'Chleb')]),
    ];
    messages = [];
    reminders = [];
    server = FakeServer((r) {
      final route = '${r.method} ${r.url.path}';
      switch (route) {
        case 'GET /v1/lists':
          return (200, {'lists': lists});
        case 'GET /v1/reminders':
          return (200, {'reminders': reminders});
        case 'GET /v1/messages':
          final unread = messages
              .where((m) => m['read'] != true && m['from'] != 'me')
              .length;
          return (200, {'messages': messages, 'unread': unread});
        case 'POST /v1/lists':
          return (201, {'id': 'L2'});
        case 'POST /v1/messages':
          return (201, {'id': 'M-new'});
        case 'POST /v1/reminders/R1/done':
          return (200, {'next': '2027-01-27', 'completed': false});
        case 'PATCH /v1/lists/L1/items/I1':
          return failPatch ? (500, {'error': 'boom'}) : (200, {'status': 'ok'});
        case 'DELETE /v1/lists/L1/items/I2':
          return (200, {'status': 'ok'});
      }
      return (200, {'status': 'ok'});
    });
  });

  group('wiązanie z profilem', () {
    test('bind pobiera dane, a zmiana profilu czyści poprzednie', () async {
      final c = build();
      c.bind('me');
      await until(() => c.loaded);

      expect(c.lists.single.name, 'Spożywcze');
      expect(c.loaded, isTrue);
      expect(
          server.log,
          containsAll(
              ['GET /v1/lists', 'GET /v1/reminders', 'GET /v1/messages']));

      c.bind('other');
      expect(c.profileId, 'other');
      // Dane poprzedniego profilu znikają od razu, zanim dojdą nowe.
      expect(c.lists, isEmpty);
    });

    test('bind(null) i ten sam profil nic nie pobierają', () async {
      final c = build();
      c.bind(null);
      expect(server.log, isEmpty);
      c.bind('me');
      await until(() => c.loaded);
      final calls = server.log.length;
      c.bind('me');
      expect(server.log.length, calls);
    });
  });

  group('listy zakupów', () {
    test('odhaczenie zmienia stan od razu, przed odpowiedzią serwera',
        () async {
      final c = build()..bind('me');
      await until(() => c.loaded);

      final future = c.setItemChecked('L1', 'I1', true);
      expect(c.lists.single.items.first.checked, isTrue,
          reason: 'optymistycznie, bez czekania na sieć');
      expect(c.lists.single.openCount, 1);
      await future;

      final patch = server.requests.firstWhere((r) => r.method == 'PATCH');
      expect(jsonDecode(patch.body), {'checked': true});
    });

    test('błąd serwera cofa odhaczenie do stanu z serwera', () async {
      final c = build()..bind('me');
      await until(() => c.loaded);
      failPatch = true;

      await expectLater(
          c.setItemChecked('L1', 'I1', true), throwsA(isA<ApiException>()));

      expect(c.lists.single.items.first.checked, isFalse);
    });

    test('usunięcie pozycji znika od razu', () async {
      final c = build()..bind('me');
      await until(() => c.loaded);

      await c.deleteItem('L1', 'I2');

      expect(c.lists.single.items.map((i) => i.text), ['Mleko']);
    });

    test('udostępnianie wysyła listę identyfikatorów profili', () async {
      final c = build()..bind('me');
      await until(() => c.loaded);

      await c.updateList('L1', sharedWith: ['kid', 'gran']);

      final patch = server.requests.firstWhere(
          (r) => r.method == 'PATCH' && r.url.path == '/v1/lists/L1');
      expect(jsonDecode(patch.body), {
        'sharedWith': ['kid', 'gran']
      });
    });

    test('nowa lista z udostępnieniem', () async {
      final c = build()..bind('me');
      await until(() => c.loaded);

      await c.createList('Apteka', sharedWith: ['kid']);

      final post = server.requests
          .firstWhere((r) => r.method == 'POST' && r.url.path == '/v1/lists');
      expect(jsonDecode(post.body), {
        'name': 'Apteka',
        'sharedWith': ['kid']
      });
    });
  });

  group('przypomnienia', () {
    test('odhaczenie wysyła dzień wykonania z telefonu i odświeża listę',
        () async {
      final c = build()..bind('me');
      await until(() => c.loaded);
      final before = server.log.where((l) => l == 'GET /v1/reminders').length;

      await c.completeReminder('R1', now: DateTime(2026, 10, 27, 23, 30));

      final post = server.requests
          .firstWhere((r) => r.url.path == '/v1/reminders/R1/done');
      expect(jsonDecode(post.body), {'doneOn': '2026-10-27'},
          reason: 'lokalny dzień, nie UTC');
      expect(
          server.log.where((l) => l == 'GET /v1/reminders').length, before + 1);
    });

    test('zmiana przypomnień powiadamia planistę powiadomień', () async {
      List<Reminder>? seen;
      reminders = [
        {
          'id': 'R1',
          'ownerProfileId': 'me',
          'kind': 'water_filter',
          'title': 'Filtr',
          'note': null,
          'date': '2026-11-01',
          'repeatEvery': 3,
          'repeatUnit': 'month',
          'anchor': 'afterDone',
          'leadDays': 3,
          'shared': true,
          'completedAt': null,
        },
      ];
      final c = build(onReminders: (r) => seen = r)..bind('me');
      await until(() => c.loaded);

      expect(seen!.single.title, 'Filtr');
      expect(seen!.single.anchorAfterDone, isTrue);
      expect(seen!.single.kind, ReminderKind.waterFilter);
      expect(c.reminders.single.leadDays, 3);
    });

    test('tworzenie przypomnienia wysyła komplet pól', () async {
      final c = build()..bind('me');
      await until(() => c.loaded);

      await c.createReminder(Reminder(
        id: '',
        ownerProfileId: 'me',
        kind: ReminderKind.birthday,
        title: 'Urodziny Ani',
        date: DateTime(2026, 3, 14),
        repeatEvery: 1,
        repeatUnit: RepeatUnit.year,
        leadDays: 7,
      ));

      final post = server.requests.firstWhere(
          (r) => r.method == 'POST' && r.url.path == '/v1/reminders');
      expect(jsonDecode(post.body), {
        'kind': 'birthday',
        'title': 'Urodziny Ani',
        'note': null,
        'date': '2026-03-14',
        'repeatEvery': 1,
        'repeatUnit': 'year',
        'anchor': 'fixed',
        'leadDays': 7,
        'shared': true,
      });
    });
  });

  group('wiadomości', () {
    test('nieprzeczytane są liczone z odpowiedzi serwera', () async {
      messages = [
        messageJson('M1', 'mama'),
        messageJson('M2', 'mama', read: true),
        messageJson('M3', 'me')
      ];
      final c = build()..bind('me');
      await until(() => c.loaded);
      expect(c.unread, 1);
    });

    test('stare wiadomości nie wywołują powiadomień, nowe tak, własne nie',
        () async {
      final fresh = <String>[];
      messages = [messageJson('M1', 'mama')];
      final c = build(onNew: (m) => fresh.addAll(m.map((x) => x.id)))
        ..bind('me');
      await until(() => c.loaded);
      expect(fresh, isEmpty, reason: 'pierwsze pobranie to punkt odniesienia');

      messages = [
        messageJson('M2', 'mama'),
        messageJson('M3', 'me'),
        ...messages
      ];
      c.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      c.stopPolling();

      expect(fresh, ['M2'],
          reason: 'tylko cudza, nowa i nieprzeczytana; powiadomienie raz');
    });

    test('wysłanie wiadomości do jednego profilu i do wszystkich', () async {
      final c = build()..bind('me');
      await until(() => c.loaded);

      await c.sendMessage('Hej, wracam później', to: 'kid');
      await c.sendMessage('Obiad o 18');

      final posts = server.requests
          .where((r) => r.method == 'POST' && r.url.path == '/v1/messages')
          .toList();
      expect(jsonDecode(posts[0].body),
          {'to': 'kid', 'body': 'Hej, wracam później'});
      expect(jsonDecode(posts[1].body), {'to': null, 'body': 'Obiad o 18'});
    });

    test('odpytywanie milknie po zatrzymaniu', () async {
      final c = build()..bind('me');
      await until(() => c.loaded);
      c.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.stopPolling();
      final calls = server.log.length;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(server.log.length, calls);
    });
  });

  test('błąd odświeżania zostaje w stanie, nie wywala aplikacji', () async {
    server = FakeServer((r) => (403, {'error': 'profile_required'}));
    final c = build()..bind('me');
    await until(() => c.error != null);
    expect(c.error, isNotNull);
    expect(c.loaded, isFalse);
  });
}
