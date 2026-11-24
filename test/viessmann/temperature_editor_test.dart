import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/viessmann/viessmann_models.dart';
import 'package:nestiq/widgets/heating_cards.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  const range = NumberRange(min: 30, max: 60, step: 1);

  Future<void> pumpEditor(
    WidgetTester tester, {
    num value = 58,
    bool enabled = true,
    required List<num> saved,
  }) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TemperatureEditor(
          value: value,
          range: range,
          enabled: enabled,
          onSave: (v) async => saved.add(v),
        ),
      ),
    ));
    await settle(tester);
  }

  testWidgets('przycisk + zatrzymuje się na górnej granicy zakresu',
      (tester) async {
    await pumpEditor(tester, value: 59, saved: []);

    await tester.tap(find.byTooltip('Więcej'));
    await settle(tester);
    expect(find.text('60 °C'), findsOneWidget);

    final plus =
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add));
    expect(plus.onPressed, isNull, reason: 'na maksimum nie ma dalej');
  });

  testWidgets('przycisk − zatrzymuje się na dolnej granicy', (tester) async {
    await pumpEditor(tester, value: 30, saved: []);
    final minus = tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove));
    expect(minus.onPressed, isNull);
  });

  testWidgets(
      'zapis wysyła wybraną wartość, a przycisk znika po potwierdzeniu przez piec',
      (tester) async {
    final saved = <num>[];
    await pumpEditor(tester, value: 50, saved: saved);
    expect(find.textContaining('Zapisz'), findsNothing,
        reason: 'bez zmiany nie ma co zapisywać');

    await tester.tap(find.byTooltip('Mniej'));
    await settle(tester);
    await tester.tap(find.text('Zapisz 49 °C'));
    await settle(tester);
    expect(saved, [49]);

    // Piec potwierdza nową wartość: zmiana przestaje być „niezapisana”.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TemperatureEditor(
            value: 49,
            range: range,
            enabled: true,
            onSave: (v) async => saved.add(v)),
      ),
    ));
    await settle(tester);
    expect(find.textContaining('Zapisz'), findsNothing);
    expect(find.text('49 °C'), findsOneWidget);
  });

  testWidgets('wyłączony edytor nie pozwala niczego zmienić', (tester) async {
    await pumpEditor(tester, enabled: false, saved: []);

    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove))
            .onPressed,
        isNull);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
  });

  testWidgets('niepoprawna wartość z pieca poza zakresem nie wywraca suwaka',
      (tester) async {
    await pumpEditor(tester, value: 85, saved: []);
    expect(tester.takeException(), isNull);
  });
}
