import 'package:nestiq/notifications/fault_background.dart';
import 'package:nestiq/viessmann/fault_service.dart';
import 'package:nestiq/viessmann/fault_monitor.dart';
import 'package:nestiq/viessmann/viessmann_models.dart';

class MemoryFaultStore implements FaultStore {
  bool on = false;
  Set<String>? known;

  @override
  Future<bool> enabled() async => on;

  @override
  Future<void> setEnabled(bool value) async => on = value;

  @override
  Future<Set<String>?> seen() async => known == null ? null : {...known!};

  @override
  Future<void> saveSeen(Set<String> ids) async => known = {...ids};

  @override
  Future<void> clearSeen() async => known = null;
}

class RecordingNotifier implements FaultNotifier {
  final shown = <HeatingFault>[];

  @override
  Future<void> show(HeatingFault fault) async => shown.add(fault);
}

class RecordingScheduler implements FaultScheduler {
  var starts = 0;
  var stops = 0;

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async => stops++;
}

FaultService testFaults() =>
    FaultService(notifier: RecordingNotifier(), store: MemoryFaultStore());
