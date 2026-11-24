import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/screens/tuya_screen.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/tuya/tuya_models.dart';
import 'package:nestiq/tuya/tuya_store.dart';

import 'fakes.dart';

void main() {
  Future<TuyaController> pump(WidgetTester tester,
      {TuyaCloudCredentials? credentials, FakeCloud? cloud}) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryTuyaStore()
      ..saved = StoredTuya(credentials: credentials);
    final tuya =
        TuyaController(store: store, cloudFactory: (_) => cloud ?? FakeCloud());
    await tuya.load();
    addTearDown(tuya.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TuyaScreen(tuya: tuya, rooms: RoomsController())));
    await tester.pump(const Duration(milliseconds: 500));
    return tuya;
  }

  testWidgets('bez zapisanych danych pokazuje formularz', (tester) async {
    await pump(tester);

    expect(find.text('Access ID'), findsOneWidget);
    expect(find.text('Zapisz i zaimportuj urządzenia'), findsOneWidget);
  });

  testWidgets('po zapisaniu danych pokazuje skrót, a sekret nie jest widoczny',
      (tester) async {
    await pump(tester,
        credentials: const TuyaCloudCredentials(
            accessId: 'abcd1234efgh5678', accessSecret: 'SEKRET-DO-UKRYCIA'));

    expect(find.text('Dane chmury zapisane na tym telefonie'), findsOneWidget);
    expect(find.textContaining('abcd••••'), findsOneWidget);
    expect(find.textContaining('SEKRET-DO-UKRYCIA'), findsNothing);
    expect(find.textContaining('abcd1234efgh5678'), findsNothing);
    expect(find.byType(TextField), findsNothing, reason: 'formularz ukryty');
  });

  testWidgets(
      '„Zmień dane” otwiera formularz bez sekretu, „Anuluj” wraca do skrótu',
      (tester) async {
    await pump(tester,
        credentials: const TuyaCloudCredentials(
            accessId: 'abcd1234efgh5678', accessSecret: 'SEKRET-DO-UKRYCIA'));

    await tester.tap(find.text('Zmień dane'));
    await tester.pump(const Duration(milliseconds: 300));

    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].controller!.text, 'abcd1234efgh5678');
    expect(fields[1].controller!.text, isEmpty,
        reason: 'sekretu nie wczytujemy z powrotem do pola');

    await tester.tap(find.text('Anuluj'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Dane chmury zapisane na tym telefonie'), findsOneWidget);
  });

  testWidgets(
      'odświeżenie używa zapisanych danych, bez wpisywania ich ponownie',
      (tester) async {
    final cloud = FakeCloud()
      ..devices = [
        const TuyaDevice(
            id: 'dev9',
            name: 'Garaż',
            localKey: '0123456789abcdef',
            channels: [
              TuyaChannel(dpId: 1, code: 'switch_1', name: 'Przycisk 1'),
            ]),
      ];
    final tuya = await pump(tester,
        credentials:
            const TuyaCloudCredentials(accessId: 'id', accessSecret: 'secret'),
        cloud: cloud);

    await tester.tap(find.text('Odśwież urządzenia z chmury'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tuya.devices.map((d) => d.id), ['dev9']);
    expect(find.text('Garaż'), findsOneWidget);
  });
}
