import 'dart:async';

import 'package:flutter/foundation.dart';

import '../notifications/fault_background.dart';
import 'fault_monitor.dart';
import 'viessmann_models.dart';

/// Wynik próby włączenia powiadomień.
enum FaultEnableResult { enabled, permissionDenied }

/// Powiadomienia o usterkach pieca: włączanie, zgoda systemowa, sprawdzanie w tle
/// i otwieranie ekranu usterek po dotknięciu powiadomienia.
class FaultService extends ChangeNotifier {
  FaultService({
    FaultStore? store,
    required FaultNotifier notifier,
    FaultScheduler? scheduler,
    Future<bool> Function()? requestPermission,
    Stream<String>? taps,
    bool launchedFromNotification = false,
  })  : _store = store ?? PrefsFaultStore(),
        _scheduler = scheduler,
        _requestPermission = requestPermission,
        pendingOpen = launchedFromNotification {
    monitor = FaultMonitor(store: _store, notifier: notifier);
    _tapSub = taps?.listen((payload) {
      pendingOpen = true;
      notifyListeners();
    });
  }

  final FaultStore _store;
  final FaultScheduler? _scheduler;
  final Future<bool> Function()? _requestPermission;
  late final FaultMonitor monitor;
  StreamSubscription<String>? _tapSub;

  bool enabled = false;
  bool loaded = false;

  /// Dotknięto powiadomienie, a ekran usterek jeszcze nie został otwarty.
  bool pendingOpen;

  Future<void> load() async {
    enabled = await _store.enabled();
    loaded = true;
    notifyListeners();
    // Po restarcie aplikacji upewniamy się, że zadanie w tle nadal jest zaplanowane.
    if (enabled) unawaited(_scheduler?.start());
  }

  Future<FaultEnableResult> setEnabled(bool value) async {
    if (value) {
      final granted = await (_requestPermission?.call() ?? Future.value(true));
      if (!granted) return FaultEnableResult.permissionDenied;
      await _store.setEnabled(true);
      // Stary punkt odniesienia mógł pochodzić sprzed wyłączenia.
      await monitor.reset();
      await _scheduler?.start();
    } else {
      await _store.setEnabled(false);
      await monitor.reset();
      await _scheduler?.stop();
    }
    enabled = value;
    notifyListeners();
    return FaultEnableResult.enabled;
  }

  /// Wywoływane po każdym udanym odczycie pieca w aplikacji.
  Future<void> handle(HeatingState state) async {
    if (!enabled) return;
    await monitor.process(state);
  }

  /// Ekran usterek został otwarty (albo użytkownik nie może go zobaczyć).
  void consumeOpenRequest() {
    if (!pendingOpen) return;
    pendingOpen = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _tapSub?.cancel();
    super.dispose();
  }
}
