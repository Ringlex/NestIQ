import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../viessmann/fault_monitor.dart';
import '../viessmann/viessmann_controller.dart';
import 'notification_service.dart';

const faultTaskName = 'nestiq.faultCheck';
const faultTaskId = 'nestiq.faultCheck.periodic';

/// Jedno sprawdzenie pieca w tle: odczyt stanu i powiadomienie o nowych usterkach.
/// Wydzielone z zadania systemowego, żeby dało się je przetestować.
Future<void> runFaultCheck({
  required ViessmannController viessmann,
  required FaultMonitor monitor,
}) async {
  if (!await monitor.store.enabled()) return;
  await viessmann.load();
  if (!viessmann.isConfigured) return;
  // Odczyt wymuszony: zadanie w tle uruchamia się rzadko, więc nie ma sensu go pomijać.
  await viessmann.refresh(force: true);
  final state = viessmann.state;
  if (state != null) await monitor.process(state);
}

/// Punkt wejścia zadania w tle (Android: WorkManager, iOS: Background Fetch).
@pragma('vm:entry-point')
void faultCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final notifier = LocalFaultNotifier.instance;
      await notifier.init();
      await runFaultCheck(
        viessmann: ViessmannController(),
        monitor: FaultMonitor(store: PrefsFaultStore(), notifier: notifier),
      );
      return true;
    } catch (_) {
      // Kolejna próba za okres; nie ponawiamy natychmiast, żeby nie zużywać limitu API.
      return true;
    }
  });
}

/// Harmonogram sprawdzania w tle.
abstract interface class FaultScheduler {
  Future<void> start();
  Future<void> stop();
}

class WorkmanagerFaultScheduler implements FaultScheduler {
  bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    await Workmanager()
        .initialize(faultCallbackDispatcher, isInDebugMode: false);
    _initialized = true;
  }

  @override
  Future<void> start() async {
    await _init();
    // iOS nie ma zadań okresowych (tylko Background Fetch, którym zarządza system),
    // więc wystarcza zainicjowanie wtyczki, żeby wybudzenia trafiały do naszego kodu.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    // Android: nie częściej niż co 15 minut, system sam wybiera chwilę. 30 minut to
    // ok. 48 zapytań na dobę z limitu 1450.
    await Workmanager().registerPeriodicTask(
      faultTaskId,
      faultTaskName,
      frequency: const Duration(minutes: 30),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  @override
  Future<void> stop() async {
    await _init();
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await Workmanager().cancelByUniqueName(faultTaskId);
  }
}
