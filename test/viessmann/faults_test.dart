import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/notifications/fault_background.dart';
import 'package:nestiq/viessmann/fault_monitor.dart';
import 'package:nestiq/viessmann/fault_service.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/viessmann/viessmann_faults.dart';
import 'package:nestiq/viessmann/viessmann_models.dart';
import 'package:nestiq/viessmann/viessmann_store.dart';

import 'fakes.dart';
import 'fakes_faults.dart';
import 'fixtures.dart';

/// Funkcje pieca z dopisanymi usterkami.
List<Map<String, dynamic>> featuresWith({
  bool lock = false,
  List<Map<String, String>> errors = const [],
  List<Map<String, String>> service = const [],
  List<Map<String, String>> info = const [],
}) {
  Map<String, dynamic> messages(
          String name, List<Map<String, String>> entries) =>
      feat(name, props: {
        'entries': {'type': 'array', 'value': entries}
      });

  final base = vitodensFeatures().where((f) {
    final n = f['feature'];
    return n != 'device.lock.malfunction';
  }).toList();
  return [
    ...base,
    feat('device.lock.malfunction', props: {'active': flag(lock)}),
    if (errors.isNotEmpty) messages('device.messages.errors.raw', errors),
    messages('device.messages.service.raw', service),
    messages('device.messages.info.raw', info),
  ];
}

Map<String, String> entry(String code, String at) =>
    {'errorCode': code, 'timestamp': at, 'priority': 'error'};

HeatingState stateOf(List<Map<String, dynamic>> data) =>
    HeatingState.parse(data);

void main() {
  group('usterki z odpowiedzi pieca', () {
    test('spokojny piec nie ma usterek (kody statusu S.x to nie usterki)', () {
      final state = stateOf(featuresWith());
      expect(state.faults, isEmpty);
      expect(state.alerts, isEmpty);
      expect(state.messages, isNotEmpty,
          reason: 'status.raw zostaje osobno jako komunikaty stanu');
    });

    test('blokada awaryjna, usterka, serwis i informacja są rozpoznawane', () {
      final state = stateOf(featuresWith(
        lock: true,
        errors: [entry('F.1000', '2026-10-27T10:00:00.000Z')],
        service: [entry('A.2', '2026-10-26T08:00:00.000Z')],
        info: [entry('I.5', '2026-10-25T08:00:00.000Z')],
      ));

      expect(state.faults.map((f) => f.kind),
          [FaultKind.lock, FaultKind.error, FaultKind.service, FaultKind.info]);
      expect(state.alerts.map((f) => f.kind),
          [FaultKind.lock, FaultKind.error, FaultKind.service],
          reason: 'o komunikatach informacyjnych nie powiadamiamy');
      expect(state.faults[1].code, 'F.1000');
      expect(state.faults[1].time, isNotNull);
    });

    test('w obrębie rodzaju najnowsze są pierwsze', () {
      final state = stateOf(featuresWith(service: [
        entry('A.1', '2026-10-01T08:00:00.000Z'),
        entry('A.3', '2026-10-20T08:00:00.000Z'),
        entry('A.2', '2026-10-10T08:00:00.000Z'),
      ]));
      expect(state.faults.map((f) => f.code), ['A.3', 'A.2', 'A.1']);
    });

    test('identyfikator zdarzenia zależy od kodu i czasu, blokada ma stały',
        () {
      final a = stateOf(
              featuresWith(errors: [entry('F.1', '2026-10-27T10:00:00.000Z')]))
          .faults
          .single;
      final b = stateOf(
              featuresWith(errors: [entry('F.1', '2026-10-28T10:00:00.000Z')]))
          .faults
          .single;
      expect(a.id, isNot(b.id),
          reason: 'ta sama usterka, ale kolejne wystąpienie');
      expect(stateOf(featuresWith(lock: true)).faults.single.id, 'lock');
    });

    test('opisy mówią, co się stało i co zrobić, bez wymyślania znaczenia kodu',
        () {
      const error = HeatingFault(kind: FaultKind.error, code: 'F.1000');
      expect(faultTitle(error), contains('F.1000'));
      expect(faultWhat(error), contains('F.1000'));
      expect(faultAdvice(error), contains('instrukcji'));
      const lock = HeatingFault(kind: FaultKind.lock, code: 'LOCK');
      expect(faultWhat(lock), contains('blokadę'));
      expect(faultAdvice(lock), contains('serwis'));
    });
  });

  group('wykrywanie nowych usterek', () {
    late MemoryFaultStore store;
    late RecordingNotifier notifier;
    late FaultMonitor monitor;

    setUp(() {
      store = MemoryFaultStore()..on = true;
      notifier = RecordingNotifier();
      monitor = FaultMonitor(store: store, notifier: notifier);
    });

    test(
        'pierwszy odczyt tylko zapamiętuje stan i nie zasypuje powiadomieniami',
        () async {
      final state = stateOf(featuresWith(
          lock: true, service: [entry('A.1', '2026-01-01T08:00:00.000Z')]));

      expect(await monitor.process(state), isEmpty);
      expect(notifier.shown, isEmpty);
      expect(store.known, isNotNull);
    });

    test('nowa usterka po punkcie odniesienia powiadamia dokładnie raz',
        () async {
      await monitor.process(stateOf(featuresWith()));

      final broken = stateOf(
          featuresWith(errors: [entry('F.2', '2026-10-27T10:00:00.000Z')]));
      final first = await monitor.process(broken);
      final second = await monitor.process(broken);

      expect(first.single.code, 'F.2');
      expect(second, isEmpty);
      expect(notifier.shown.length, 1);
    });

    test('usterka, która ustąpiła i wróciła, powiadamia ponownie', () async {
      await monitor.process(stateOf(featuresWith()));
      await monitor.process(stateOf(featuresWith(lock: true)));
      expect(notifier.shown.length, 1);

      await monitor.process(stateOf(featuresWith())); // blokada zdjęta
      await monitor.process(stateOf(featuresWith(lock: true))); // znów blokada

      expect(notifier.shown.length, 2);
    });

    test('komunikat informacyjny nie wywołuje powiadomienia', () async {
      await monitor.process(stateOf(featuresWith()));
      await monitor.process(stateOf(
          featuresWith(info: [entry('I.9', '2026-10-27T10:00:00.000Z')])));
      expect(notifier.shown, isEmpty);
    });

    test('wiele nowych usterek naraz daje po powiadomieniu na każdą', () async {
      await monitor.process(stateOf(featuresWith()));
      await monitor.process(stateOf(featuresWith(
        lock: true,
        errors: [entry('F.7', '2026-10-27T10:00:00.000Z')],
      )));
      expect(notifier.shown.map((f) => f.code), ['LOCK', 'F.7']);
    });

    test('przy wyłączonych powiadomieniach nic się nie dzieje', () async {
      store.on = false;
      expect(await monitor.process(stateOf(featuresWith(lock: true))), isEmpty);
      expect(store.known, isNull);
    });

    test('ponowne włączenie zaczyna od nowego punktu odniesienia', () async {
      await monitor.process(stateOf(featuresWith()));
      await monitor.reset();
      expect(store.known, isNull);

      // Piec ma już usterkę z okresu, gdy powiadomienia były wyłączone: nie wolno o niej krzyczeć.
      expect(await monitor.process(stateOf(featuresWith(lock: true))), isEmpty);
      expect(notifier.shown, isEmpty);
    });
  });

  group('usługa powiadomień', () {
    test('włączenie prosi o zgodę, zapisuje wybór i planuje sprawdzanie w tle',
        () async {
      final store = MemoryFaultStore();
      final scheduler = RecordingScheduler();
      var asked = 0;
      final service = FaultService(
        store: store,
        notifier: RecordingNotifier(),
        scheduler: scheduler,
        requestPermission: () async {
          asked++;
          return true;
        },
      );

      final result = await service.setEnabled(true);

      expect(result, FaultEnableResult.enabled);
      expect(service.enabled, isTrue);
      expect(store.on, isTrue);
      expect(asked, 1);
      expect(scheduler.starts, 1);
    });

    test('brak zgody systemowej nie włącza powiadomień', () async {
      final store = MemoryFaultStore();
      final scheduler = RecordingScheduler();
      final service = FaultService(
        store: store,
        notifier: RecordingNotifier(),
        scheduler: scheduler,
        requestPermission: () async => false,
      );

      expect(
          await service.setEnabled(true), FaultEnableResult.permissionDenied);
      expect(service.enabled, isFalse);
      expect(store.on, isFalse);
      expect(scheduler.starts, 0);
    });

    test('wyłączenie zatrzymuje sprawdzanie i zapomina stan', () async {
      final store = MemoryFaultStore();
      final scheduler = RecordingScheduler();
      final service = FaultService(
          store: store, notifier: RecordingNotifier(), scheduler: scheduler);
      await service.setEnabled(true);
      store.known = {'lock'};

      await service.setEnabled(false);

      expect(store.on, isFalse);
      expect(store.known, isNull);
      expect(scheduler.stops, 1);
    });

    test(
        'po restarcie aplikacji ustawienie wraca, a zadanie w tle jest planowane ponownie',
        () async {
      final store = MemoryFaultStore()..on = true;
      final scheduler = RecordingScheduler();
      final service = FaultService(
          store: store, notifier: RecordingNotifier(), scheduler: scheduler);

      await service.load();
      await Future<void>.delayed(Duration.zero);

      expect(service.enabled, isTrue);
      expect(scheduler.starts, 1);
    });

    test('dotknięcie powiadomienia ustawia prośbę o otwarcie ekranu usterek',
        () async {
      final taps = Stream<String>.fromIterable(['faults']).asBroadcastStream();
      final service = FaultService(
          store: MemoryFaultStore(), notifier: RecordingNotifier(), taps: taps);
      await Future<void>.delayed(Duration.zero);

      expect(service.pendingOpen, isTrue);
      service.consumeOpenRequest();
      expect(service.pendingOpen, isFalse);
    });

    test('zimny start z powiadomienia też prosi o otwarcie ekranu usterek', () {
      final service = FaultService(
        store: MemoryFaultStore(),
        notifier: RecordingNotifier(),
        launchedFromNotification: true,
      );
      expect(service.pendingOpen, isTrue);
    });
  });

  group('sprawdzanie w tle', () {
    late FakeViessmannApi api;

    ViessmannController controller(
        {required bool configured, List<Map<String, dynamic>>? data}) {
      final store = MemoryViessmannStore();
      if (configured) {
        store.saved = const StoredViessmann(
          clientId: '1561f44a5fbce8acf0c3cea9334e5af1',
          refreshToken: 'R',
          device: testDevice,
        );
      }
      return ViessmannController(
        store: store,
        apiFactory: ({required token, required onCall}) {
          api = FakeViessmannApi(onCall);
          if (data != null) api.data = data;
          return api;
        },
        minRefreshGap: Duration.zero,
        settleDelay: Duration.zero,
        isInForeground: () => true,
      );
    }

    test('jedno sprawdzenie odczytuje piec i powiadamia o nowej usterce',
        () async {
      final faultStore = MemoryFaultStore()..on = true;
      final notifier = RecordingNotifier();
      final monitor = FaultMonitor(store: faultStore, notifier: notifier);

      // Punkt odniesienia: piec bez usterek.
      await runFaultCheck(
          viessmann: controller(configured: true), monitor: monitor);
      expect(notifier.shown, isEmpty);

      // Piec zgłasza blokadę przy następnym sprawdzeniu.
      await runFaultCheck(
          viessmann:
              controller(configured: true, data: featuresWith(lock: true)),
          monitor: monitor);

      expect(notifier.shown.single.kind, FaultKind.lock);
    });

    test(
        'bez włączonych powiadomień albo bez połączenia z Viessmannem nie ma zapytań',
        () async {
      final monitor = FaultMonitor(
          store: MemoryFaultStore(), notifier: RecordingNotifier());
      final off = controller(configured: true);
      await runFaultCheck(viessmann: off, monitor: monitor);
      expect(off.state, isNull);

      final faultStore = MemoryFaultStore()..on = true;
      final disconnected = controller(configured: false);
      await runFaultCheck(
        viessmann: disconnected,
        monitor: FaultMonitor(store: faultStore, notifier: RecordingNotifier()),
      );
      expect(disconnected.state, isNull);
    });
  });
}
