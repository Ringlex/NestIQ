import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/devices/smart_device.dart';
import 'package:nestiq/tuya/tuya_cloud_client.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/tuya/tuya_models.dart';
import 'package:nestiq/tuya/tuya_store.dart';
import 'package:nestiq/widgets/sensor_sheet.dart';

import 'fakes.dart';
import 'tuya_sensor_test.dart' show sensor;

// Funkcje (to, co wolno zapisać) typowego czujnika `wsdcg` z dokumentacji Tuya.
Map<String, dynamic> spec() => {
      'functions': [
        {
          'code': 'temp_unit_convert',
          'type': 'Enum',
          'values': jsonEncode({
            'range': ['c', 'f']
          }),
        },
        {
          'code': 'maxtemp_set',
          'type': 'Integer',
          'values': jsonEncode(
              {'unit': '℃', 'min': -200, 'max': 600, 'scale': 1, 'step': 5}),
        },
        {
          'code': 'minihum_set',
          'type': 'Integer',
          'values': jsonEncode(
              {'unit': '%', 'min': 0, 'max': 100, 'scale': 0, 'step': 1}),
        },
        // Nieznane kody (podświetlenie, tryby serwisowe) zostają poza aplikacją.
        {'code': 'switch_led', 'type': 'Boolean'},
        {
          'code': 'mystery_mode',
          'type': 'Integer',
          'values': jsonEncode({'min': 0, 'max': 3, 'scale': 0, 'step': 1}),
        },
      ],
      'status': <Object>[],
    };

void main() {
  group('ustawienia czujnika z opisu urządzenia', () {
    test('znane kody z zakresami, nieznane pomijane', () {
      final settings = TuyaCloudClient.sensorSettings(spec());

      expect(settings.map((s) => s.code),
          ['temp_unit_convert', 'maxtemp_set', 'minihum_set']);
      expect(settings.first.options, ['c', 'f']);
      final max = settings[1];
      expect((max.min, max.max, max.step, max.scale), (-200, 600, 5, 1));
      expect(max.value(305), 30.5);
      expect(max.raw(30.5), 305);
    });

    test('puste lub zepsute funkcje nie dają ustawień', () {
      expect(TuyaCloudClient.sensorSettings({}), isEmpty);
      expect(
          TuyaCloudClient.sensorSettings({
            'functions': [
              {
                'code': 'maxtemp_set',
                'type': 'Integer',
                'values': '{"min":5,"max":5}'
              },
              {'code': 'temp_unit_convert', 'type': 'Enum', 'values': 'x'},
            ]
          }),
          isEmpty);
    });

    test('ustawienia przeżywają zapis i odczyt', () {
      final withSettings =
          sensor.copyWith(settings: TuyaCloudClient.sensorSettings(spec()));
      final again = TuyaDevice.fromJson(
          jsonDecode(jsonEncode(withSettings.toJson()))
              as Map<String, dynamic>);

      expect(again.settings.map((s) => s.code),
          ['temp_unit_convert', 'maxtemp_set', 'minihum_set']);
      expect(again.settings[1].scale, 1);
      expect(again.settings.first.options, ['c', 'f']);
    });
  });

  group('kontroler: zmiana ustawień', () {
    late FakeCloud cloud;

    Future<TuyaController> build({bool withCloud = true}) async {
      cloud = FakeCloud()
        ..status = {
          'va_temperature': 235,
          'va_humidity': 48,
          'maxtemp_set': 300,
          'temp_unit_convert': 'c',
        };
      final device =
          sensor.copyWith(settings: TuyaCloudClient.sensorSettings(spec()));
      final c = TuyaController(
        store: MemoryTuyaStore()
          ..saved = StoredTuya(
            credentials: withCloud
                ? const TuyaCloudCredentials(accessId: 'id', accessSecret: 's')
                : null,
            devices: [device],
            mode: TuyaMode.auto,
          ),
        cloudFactory: (_) => cloud,
        sensorPollInterval: const Duration(hours: 1),
      );
      await c.load();
      c.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      addTearDown(c.dispose);
      return c;
    }

    test('bieżące wartości pochodzą z odczytu i są przeliczone', () async {
      final c = await build();
      final settings = {
        for (final s in c.settingsOf(c.devices.single)) s.code: s
      };

      expect(settings['maxtemp_set']!.value, 30.0);
      expect(settings['maxtemp_set']!.unit, '°C');
      expect(settings['temp_unit_convert']!.value, 'c');
      expect(settings['temp_unit_convert']!.options.map((o) => o.label),
          ['°C', '°F']);
      expect(settings['minihum_set']!.value, isNull,
          reason: 'urządzenie jeszcze nie zgłosiło tej wartości');
    });

    test('zapis liczby wysyła surową wartość i od razu ją pokazuje', () async {
      final c = await build();
      final setting = c
          .settingsOf(c.devices.single)
          .firstWhere((s) => s.code == 'maxtemp_set');

      await setting.set(31.5);

      expect(cloud.values, [('sen1', 'maxtemp_set', 315)]);
      expect(
          c
              .settingsOf(c.devices.single)
              .firstWhere((s) => s.code == 'maxtemp_set')
              .value,
          31.5);
    });

    test('zapis wyboru wysyła tekst opcji', () async {
      final c = await build();
      await c
          .settingsOf(c.devices.single)
          .firstWhere((s) => s.code == 'temp_unit_convert')
          .set('f');

      expect(cloud.values, [('sen1', 'temp_unit_convert', 'f')]);
    });

    test('błąd chmury kończy się czytelnym wyjątkiem i nie zmienia wartości',
        () async {
      final c = await build();
      cloud.offline = true;
      final setting = c
          .settingsOf(c.devices.single)
          .firstWhere((s) => s.code == 'maxtemp_set');

      await expectLater(
          setting.set(25.0), throwsA(isA<DeviceControlException>()));
      expect(
          c
              .settingsOf(c.devices.single)
              .firstWhere((s) => s.code == 'maxtemp_set')
              .value,
          30.0);
    });

    test('bez danych chmury ustawień nie da się zmienić', () async {
      final c = await build(withCloud: false);
      final setting = c.settingsOf(c.devices.single).first;

      await expectLater(setting.set('f'), throwsA(isA<TuyaControlException>()));
      expect(cloud.values, isEmpty);
    });
  });

  group('arkusz czujnika', () {
    final saved = <Object>[];

    SmartSensor sensorWith({List<SensorSetting> settings = const []}) =>
        SmartSensor(
          key: 'k',
          name: 'Sypialnia',
          available: true,
          temperature: 23.5,
          humidity: 48,
          battery: 15,
          updatedAt: DateTime.now(),
          settings: settings,
        );

    Future<void> open(WidgetTester tester, SmartSensor s,
        {required bool canEdit}) async {
      saved.clear();
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showSensorSheet(context, sensor: s, canEdit: canEdit),
            child: const Text('otwórz'),
          ),
        ),
      ));
      await tester.tap(find.text('otwórz'));
      await tester.pumpAndSettle();
    }

    final unit = SensorSetting(
      code: 'temp_unit_convert',
      label: 'Jednostka temperatury',
      value: 'c',
      options: const [SensorOption('c', '°C'), SensorOption('f', '°F')],
      set: (v) async => saved.add(v),
    );

    testWidgets('pokazuje odczyt i ustawienia, a zmiana wyboru jest zapisana',
        (tester) async {
      await open(tester, sensorWith(settings: [unit]), canEdit: true);

      expect(find.text('23,5°C'), findsOneWidget);
      expect(find.text('48%'), findsOneWidget);
      expect(find.text('Ustawienia czujnika'), findsOneWidget);
      expect(find.text('Jednostka temperatury'), findsOneWidget);

      await tester.tap(find.text('°F'));
      await tester.pumpAndSettle();
      expect(saved, ['f']);
    });

    testWidgets('błąd zapisu jest widoczny przy ustawieniach', (tester) async {
      final failing = SensorSetting(
        code: 'x',
        label: 'Alarm: za gorąco',
        value: 30.0,
        min: 0,
        max: 60,
        unit: '°C',
        set: (_) async => throw const TuyaControlException('Brak chmury'),
      );
      await open(tester, sensorWith(settings: [failing]), canEdit: true);

      expect(find.text('30°C'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(find.text('Brak chmury'), findsOneWidget);
      expect(find.text('30°C'), findsOneWidget,
          reason: 'nieudany zapis wraca do poprzedniej wartości');
    });

    testWidgets('profil bez uprawnień nie widzi ustawień', (tester) async {
      await open(tester, sensorWith(settings: [unit]), canEdit: false);

      expect(find.text('Jednostka temperatury'), findsNothing);
      expect(find.textContaining('zmienia administrator'), findsOneWidget);
      expect(find.text('23,5°C'), findsOneWidget);
    });

    testWidgets('czujnik bez ustawień podpowiada, co zrobić', (tester) async {
      await open(tester, sensorWith(), canEdit: true);

      expect(
          find.textContaining('odśwież urządzenia z chmury'), findsOneWidget);
      expect(find.textContaining('nie udostępnia ustawień'), findsOneWidget);
    });
  });
}
