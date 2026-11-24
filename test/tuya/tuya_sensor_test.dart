import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_cloud_client.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/tuya/tuya_models.dart';
import 'package:nestiq/tuya/tuya_store.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/widgets/sensor_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/fake_server.dart';
import '../viessmann/fakes_faults.dart';
import 'fakes.dart';

// Opis czujnika według typowego `wsdcg` z dokumentacji Tuya (va_temperature w dziesiątych części stopnia).
Map<String, dynamic> sensorSpec() => {
      'functions': <Object>[],
      'status': [
        {
          'code': 'va_temperature',
          'dp_id': 1,
          'type': 'Integer',
          'values': jsonEncode(
              {'unit': '℃', 'min': -200, 'max': 1000, 'scale': 1, 'step': 1}),
        },
        {
          'code': 'va_humidity',
          'dp_id': 2,
          'type': 'Integer',
          'values': jsonEncode(
              {'unit': '%', 'min': 0, 'max': 100, 'scale': 0, 'step': 1}),
        },
        {
          'code': 'battery_percentage',
          'dp_id': 3,
          'type': 'Integer',
          'values': jsonEncode({'scale': 0})
        },
        {'code': 'temp_unit_convert', 'dp_id': 9, 'type': 'Enum'},
      ],
    };

const sensor = TuyaDevice(
  id: 'sen1',
  name: 'Sypialnia',
  localKey: '0123456789abcdef',
  category: 'wsdcg',
  metrics: [
    TuyaMetric(
        kind: TuyaMetricKind.temperature,
        code: 'va_temperature',
        dpId: 1,
        scale: 1),
    TuyaMetric(kind: TuyaMetricKind.humidity, code: 'va_humidity', dpId: 2),
    TuyaMetric(
        kind: TuyaMetricKind.battery, code: 'battery_percentage', dpId: 3),
  ],
);

void main() {
  group('opis czujnika', () {
    test('rozpoznaje temperaturę, wilgotność i baterię oraz skalę', () {
      final metrics = TuyaCloudClient.sensorMetrics(sensorSpec());

      expect(metrics.map((m) => (m.kind, m.code, m.scale)), [
        (TuyaMetricKind.temperature, 'va_temperature', 1),
        (TuyaMetricKind.humidity, 'va_humidity', 0),
        (TuyaMetricKind.battery, 'battery_percentage', 0),
      ]);
      expect(metrics.first.value(235), 23.5);
    });

    test(
        'inne kody (temp_current, humidity_value) też działają, a przełączniki nie są czujnikami',
        () {
      final metrics = TuyaCloudClient.sensorMetrics({
        'status': [
          {'code': 'temp_current', 'type': 'Integer', 'values': '{"scale":1}'},
          {
            'code': 'humidity_value',
            'type': 'Integer',
            'values': '{"scale":0}'
          },
          {'code': 'switch_1', 'type': 'Boolean'},
        ],
      });
      expect(metrics.map((m) => m.code), ['temp_current', 'humidity_value']);
      expect(
          TuyaCloudClient.sensorMetrics({
            'status': [
              {'code': 'switch_1', 'type': 'Boolean'}
            ]
          }),
          isEmpty);
    });

    test('sama bateria nie robi z urządzenia czujnika', () {
      const battery = TuyaDevice(
        id: 'x',
        name: 'x',
        localKey: 'k',
        metrics: [
          TuyaMetric(kind: TuyaMetricKind.battery, code: 'battery_percentage')
        ],
      );
      expect(battery.isSensor, isFalse);
      expect(sensor.isSensor, isTrue);
    });

    test('metryki przeżywają zapis i odczyt', () {
      final again = TuyaDevice.fromJson(
          jsonDecode(jsonEncode(sensor.toJson())) as Map<String, dynamic>);
      expect(again.metrics.map((m) => (m.code, m.scale)), [
        ('va_temperature', 1),
        ('va_humidity', 0),
        ('battery_percentage', 0)
      ]);
    });
  });

  group('kontroler Tuya z czujnikami', () {
    late FakeCloud cloud;
    late MemoryTuyaStore store;

    Future<TuyaController> build({TuyaCloudCredentials? credentials}) async {
      cloud = FakeCloud()
        ..status = {
          'va_temperature': 235,
          'va_humidity': 48,
          'battery_percentage': 15
        };
      store = MemoryTuyaStore()
        ..saved = StoredTuya(
          credentials: credentials ??
              const TuyaCloudCredentials(accessId: 'id', accessSecret: 's'),
          devices: [sensor],
          mode: TuyaMode.auto,
        );
      final c = TuyaController(
        store: store,
        lanFactory: (d, v) =>
            throw StateError('czujnik nie łączy się lokalnie'),
        cloudFactory: (_) => cloud,
        sensorPollInterval: const Duration(milliseconds: 40),
      );
      await c.load();
      addTearDown(c.dispose);
      return c;
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 90));

    test('odczyt z chmury jest przeliczony i opatrzony czasem', () async {
      final c = await build();
      expect(c.readingOf('sen1'), isNull, reason: 'przed pierwszym odczytem');

      c.start();
      await settle();

      final r = c.readingOf('sen1')!;
      expect(r.temperature, 23.5);
      expect(r.humidity, 48);
      expect(r.battery, 15);
      expect(r.updatedAt, isNotNull);
      expect(c.sensorDevices.single.id, 'sen1');
    });

    test('bez danych chmury nic nie odpytuje, a stop kończy odpytywanie',
        () async {
      final noCloud = await build();
      noCloud.stop();
      await noCloud.clearCredentials();
      noCloud.start();
      await settle();
      expect(cloud.statusCalls, 0);

      final c = await build();
      c.start();
      await settle();
      expect(cloud.statusCalls, greaterThan(1),
          reason: 'odpytywanie cykliczne');
      c.stop();
      await settle();
      final after = cloud.statusCalls;
      await settle();
      expect(cloud.statusCalls, after);
    });

    test('błąd chmury zostawia poprzedni odczyt', () async {
      final c = await build();
      c.start();
      await settle();
      cloud.offline = true;
      await c.refresh();

      expect(c.readingOf('sen1')!.temperature, 23.5);
    });

    test('usunięcie czujnika kasuje odczyt', () async {
      final c = await build();
      c.start();
      await settle();
      await c.removeDevice('sen1');
      expect(c.readingOf('sen1'), isNull);
    });
  });

  group('formatowanie', () {
    test('temperatura z przecinkiem i wiek odczytu po polsku', () {
      expect(formatTemperature(21.46), '21,5°C');
      expect(formatTemperature(-3), '-3,0°C');
      expect(formatHumidity(47.6), '48%');
      final now = DateTime(2026, 10, 28, 12);
      expect(timeAgo(now.subtract(const Duration(seconds: 20)), now),
          'przed chwilą');
      expect(
          timeAgo(now.subtract(const Duration(minutes: 7)), now), '7 min temu');
      expect(
          timeAgo(now.subtract(const Duration(hours: 3)), now), '3 godz. temu');
      expect(timeAgo(now.subtract(const Duration(days: 2)), now), '2 dni temu');
    });
  });

  group('ekran Dom', () {
    late TuyaController tuya;
    late RoomsController rooms;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      rooms = RoomsController();
      final bedroom = await rooms.add('Sypialnia');
      await rooms.assignKey(RoomsController.tuyaSensorKey('sen1'), bedroom.id);
      final cloud = FakeCloud()
        ..status = {
          'va_temperature': 235,
          'va_humidity': 48,
          'battery_percentage': 15
        };
      tuya = TuyaController(
        store: MemoryTuyaStore()
          ..saved = StoredTuya(
            credentials:
                const TuyaCloudCredentials(accessId: 'id', accessSecret: 's'),
            devices: const [sensor],
            mode: TuyaMode.auto,
          ),
        cloudFactory: (_) => cloud,
        sensorPollInterval: const Duration(hours: 1),
      );
      await tuya.load();
      tuya.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      addTearDown(tuya.dispose);
    });

    Future<void> pumpHome(WidgetTester tester,
        {Size size = const Size(390, 1200), double scale = 1.0}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final account = AccountController(
        api: NestIqApi(
            baseUrl: 'http://test', client: FakeServer((_) => null).client),
        store: MemoryStore(),
      )
        ..active = Profile.fromJson(profileJson('a', 'Mama'))
        ..phase = AccountPhase.active;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data:
              MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: HomeScreen(
            account: account,
            session: SessionController(),
            rooms: rooms,
            tuya: tuya,
            viessmann: ViessmannController(),
            faults: testFaults(),
          ),
        ),
      ));
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets(
        'czujnik nie jest światłem, ma własną zakładkę Klimat z odczytem',
        (tester) async {
      await pumpHome(tester);

      // Na zakładce Oświetlenie czujnika nie ma.
      expect(find.text('Sypialnia'), findsNothing);
      expect(find.byTooltip('Klimat'), findsOneWidget);
      expect(find.byTooltip('W domu 23,5°C'), findsOneWidget);

      await tester.tap(find.byTooltip('Klimat').first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Sypialnia'),
          findsWidgets); // sekcja pokoju i wiersz czujnika
      expect(find.text('23,5°C'), findsWidgets);
      expect(find.text('48%'), findsOneWidget);
      expect(find.textContaining('bateria 15%'), findsOneWidget);
      expect(find.byIcon(Icons.battery_alert), findsOneWidget,
          reason: 'niski poziom baterii jest wyróżniony');
    });

    testWidgets('bez czujników nie ma zakładki Klimat', (tester) async {
      tuya.stop();
      await tuya.removeDevice('sen1');
      await pumpHome(tester);

      expect(find.byTooltip('Klimat'), findsNothing);
      expect(find.byTooltip('W domu 23,5°C'), findsNothing);
    });

    testWidgets('bez overflow na 360×640 przy skali tekstu 2.0',
        (tester) async {
      await pumpHome(tester, size: const Size(360, 640), scale: 2.0);
      await tester.tap(find.byTooltip('Klimat').first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });
}
