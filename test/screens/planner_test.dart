import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/household/household_controller.dart';
import 'package:nestiq/household/household_models.dart';
import 'package:nestiq/screens/planner/planner_screen.dart';

import '../account/fake_server.dart';

String day(DateTime d) => formatDay(d);

void main() {
  final today = dateOnly(DateTime.now());
  late FakeServer server;
  late List<Map<String, dynamic>> lists;
  late List<Map<String, dynamic>> reminders;
  late List<Map<String, dynamic>> events;
  late List<Map<String, dynamic>> messages;
  late AccountController account;
  late HouseholdController household;

  Map<String, dynamic> reminder(String id, String title, DateTime date,
          {String kind = 'custom', int every = 0, String anchor = 'fixed'}) =>
      {
        'id': id,
        'ownerProfileId': 'me',
        'kind': kind,
        'title': title,
        'note': null,
        'date': day(date),
        'repeatEvery': every,
        'repeatUnit': 'month',
        'anchor': anchor,
        'leadDays': 0,
        'shared': true,
        'completedAt': null,
      };

  setUp(() {
    lists = [
      {
        'id': 'L1',
        'name': 'Spożywcze',
        'ownerProfileId': 'me',
        'sharedWith': ['mama'],
        'items': [
          {
            'id': 'I1',
            'text': 'Mleko',
            'quantity': null,
            'checked': false,
            'checkedBy': null,
            'addedBy': 'me',
            'position': 1
          },
        ],
      },
    ];
    reminders = [
      reminder('R1', 'Wymiana filtra do wody',
          today.subtract(const Duration(days: 3)),
          kind: 'water_filter', every: 3, anchor: 'afterDone'),
      reminder('R2', 'Polisa mieszkania', today.add(const Duration(days: 10)),
          kind: 'insurance'),
    ];
    events = [
      {
        'id': 'E1',
        'ownerProfileId': 'me',
        'title': 'Wizyta u dentysty',
        'note': null,
        'startsAt': '${day(today)}T16:30',
        'endsAt': null,
        'allDay': false,
        'shared': true,
      },
    ];
    messages = [
      {
        'id': 'M1',
        'from': 'mama',
        'to': null,
        'body': 'Będę po osiemnastej',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'read': false,
      },
    ];
    server = FakeServer((r) {
      switch ('${r.method} ${r.url.path}') {
        case 'GET /v1/lists':
          return (200, {'lists': lists});
        case 'GET /v1/reminders':
          return (200, {'reminders': reminders});
        case 'GET /v1/events':
          return (200, {'events': events});
        case 'GET /v1/messages':
          final unread = messages
              .where((m) => m['read'] != true && m['from'] != 'me')
              .length;
          return (200, {'messages': messages, 'unread': unread});
      }
      return (200, {'status': 'ok', 'id': 'new'});
    });
    final api = NestIqApi(baseUrl: 'http://test', client: server.client)
      ..accessToken = 'tok';
    account = AccountController(api: api, store: MemoryStore());
    account.profiles = [
      Profile.fromJson(profileJson('me', 'Tata')),
      Profile.fromJson(profileJson('mama', 'Mama', role: 'member'))
    ];
    account.active = account.profiles.first;
    household =
        HouseholdController(api: api, pollInterval: const Duration(hours: 1));
  });

  Future<void> pumpPlanner(WidgetTester tester,
      {Size size = const Size(390, 800), double scale = 1.0}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    household.bind('me');
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: Scaffold(
            body: PlannerScreen(household: household, account: account)),
      ),
    ));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'cztery zakładki, licznik nieprzeczytanych wiadomości i lista zakupów',
      (tester) async {
    await pumpPlanner(tester);
    for (final t in ['Zakupy', 'Przypomnienia', 'Kalendarz', 'Wiadomości']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(household.unread, 1);
    expect(find.text('Spożywcze'), findsOneWidget);
  });

  testWidgets(
      'przypomnienia: zaległe na górze, „Zrobione” wysyła dzień wykonania',
      (tester) async {
    await pumpPlanner(tester);
    await openTab(tester, 'Przypomnienia');

    expect(find.text('Zaległe'), findsOneWidget);
    expect(find.text('Wymiana filtra do wody'), findsOneWidget);
    expect(find.text('Polisa mieszkania'), findsOneWidget);

    await tester.tap(find.byTooltip('Zrobione').first);
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();

    final done = server.requests
        .firstWhere((r) => r.url.path == '/v1/reminders/R1/done');
    expect(jsonDecode(done.body)['doneOn'], day(dateOnly(DateTime.now())));
  });

  testWidgets(
      'nowe przypomnienie: wzorce filtr, ekspres, ubezpieczenie, urodziny',
      (tester) async {
    await pumpPlanner(tester);
    await openTab(tester, 'Przypomnienia');
    await tester.tap(find.text('Przypomnienie'));
    await tester.pumpAndSettle();

    expect(find.text('Wymiana filtra do wody'), findsWidgets);
    expect(find.text('Czyszczenie ekspresu do kawy'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Urodziny'), 80,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Urodziny'));
    await tester.pumpAndSettle();
    expect(find.text('Czyje urodziny?'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Urodziny Oli');
    await tester.pump();
    await tester.ensureVisible(find.text('Dodaj'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dodaj'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));

    final post = server.requests
        .firstWhere((r) => r.method == 'POST' && r.url.path == '/v1/reminders');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['kind'], 'birthday');
    expect(body['leadDays'], 7);
    expect(body['repeatEvery'], 1);
    expect(body['repeatUnit'], 'year');
  });

  testWidgets('kalendarz pokazuje bieżący miesiąc i wydarzenia wybranego dnia',
      (tester) async {
    await pumpPlanner(tester);
    await openTab(tester, 'Kalendarz');
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('${today.year}'), findsWidgets);
    expect(find.text('Wizyta u dentysty'), findsOneWidget);
    expect(server.log, contains('GET /v1/events'));
  });

  testWidgets(
      'wiadomości: nowa jest widoczna, a szybka fraza trafia do pola i na serwer',
      (tester) async {
    await pumpPlanner(tester);
    await openTab(tester, 'Wiadomości');
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Będę po osiemnastej'), findsOneWidget);
    expect(server.log, contains('POST /v1/messages/read'));

    await tester.tap(find.text('Napisz'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mama').last);
    await tester.tap(find.text('Mama').last);
    await tester.pump();
    await tester.ensureVisible(find.textContaining('wychodzę po pracy'));
    await tester.tap(find.textContaining('wychodzę po pracy'));
    await tester.pump();
    await tester.ensureVisible(find.text('Wyślij'));
    await tester.tap(find.text('Wyślij'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));

    final post = server.requests
        .firstWhere((r) => r.method == 'POST' && r.url.path == '/v1/messages');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['to'], 'mama');
    expect(body['body'],
        'Hej, wychodzę po pracy z koleżanką na kawę, wrócę później');
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('bez overflow na 360×640, skala tekstu $scale', (tester) async {
      await pumpPlanner(tester, size: const Size(360, 640), scale: scale);
      for (final t in ['Zakupy', 'Przypomnienia', 'Kalendarz', 'Wiadomości']) {
        await openTab(tester, t);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('arkusze edycji bez overflow na 360×640, skala 2.0',
      (tester) async {
    await pumpPlanner(tester, size: const Size(360, 640), scale: 2.0);

    await openTab(tester, 'Przypomnienia');
    await tester.tap(find.text('Wymiana filtra do wody'));
    await tester.pumpAndSettle();
    expect(find.text('Powtarzanie'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    await openTab(tester, 'Kalendarz');
    await tester.tap(find.text('Wydarzenie'));
    await tester.pumpAndSettle();
    expect(find.text('Nowe wydarzenie'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    await openTab(tester, 'Wiadomości');
    await tester.tap(find.text('Napisz'));
    await tester.pumpAndSettle();
    expect(find.text('Nowa wiadomość'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
