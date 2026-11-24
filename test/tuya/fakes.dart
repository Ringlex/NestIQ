import 'dart:async';

import 'package:nestiq/tuya/tuya_cloud_client.dart';
import 'package:nestiq/tuya/tuya_lan_client.dart';
import 'package:nestiq/tuya/tuya_models.dart';
import 'package:nestiq/tuya/tuya_store.dart';

// Atrapy wspólne dla testów kontrolera i ekranu Dom.

class MemoryTuyaStore implements TuyaStore {
  StoredTuya saved = const StoredTuya();

  @override
  Future<StoredTuya> load() async => saved;

  @override
  Future<void> saveCredentials(TuyaCloudCredentials? c) async => saved =
      StoredTuya(credentials: c, devices: saved.devices, mode: saved.mode);

  @override
  Future<void> saveDevices(List<TuyaDevice> d) async => saved =
      StoredTuya(credentials: saved.credentials, devices: d, mode: saved.mode);

  @override
  Future<void> saveMode(TuyaMode m) async => saved = StoredTuya(
      credentials: saved.credentials, devices: saved.devices, mode: m);
}

class FakeLink implements TuyaLanLink {
  FakeLink(this.version, {required this.world});

  final String version;
  final World world;
  final _updates = StreamController<Map<String, Object?>>.broadcast();
  final _closed = Completer<void>();
  bool connected = false;

  @override
  Stream<Map<String, Object?>> get updates => _updates.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isConnected => connected && !_closed.isCompleted;

  @override
  Future<void> connect() async {
    world.connectAttempts.add(version);
    if (version != world.acceptedVersion) {
      throw const TuyaLanException('nie odpowiada');
    }
    connected = true;
    world.links.add(this);
  }

  @override
  Future<Map<String, Object?>> queryStatus() async => Map.of(world.dps);

  @override
  Future<void> setDps(Map<String, Object?> dps) async {
    if (world.failSet) throw const TuyaLanException('rozłączone');
    world.setCalls.add(dps);
    world.dps.addAll(dps);
  }

  void push(Map<String, Object?> dps) => _updates.add(dps);

  void drop() {
    connected = false;
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> close() async => drop();
}

class World {
  String acceptedVersion = '3.4';
  bool failSet = false;
  final dps = <String, Object?>{'1': false, '2': true};
  final connectAttempts = <String>[];
  final setCalls = <Map<String, Object?>>[];
  final links = <FakeLink>[];
}

class FakeCloud implements TuyaCloudApi {
  final commands = <(String, String, bool)>[];
  Map<String, bool> states = {'switch_1': true, 'switch_2': false};
  Map<String, Object?> status = {};
  int statusCalls = 0;
  bool offline = false;
  List<TuyaDevice> devices = [];

  @override
  Future<List<TuyaDevice>> importDevices() async => devices;

  @override
  Future<void> setSwitch(String deviceId, String code, bool on) async {
    if (offline) throw const TuyaCloudException('brak chmury');
    commands.add((deviceId, code, on));
    states[code] = on;
  }

  final values = <(String, String, Object)>[];

  @override
  Future<void> setValue(String deviceId, String code, Object value) async {
    if (offline) throw const TuyaCloudException('brak chmury');
    values.add((deviceId, code, value));
  }

  @override
  Future<Map<String, Object?>> deviceStatus(String deviceId) async {
    if (offline) throw const TuyaCloudException('brak chmury');
    statusCalls++;
    return status;
  }

  @override
  Future<Map<String, bool>> switchStates(String deviceId) async {
    if (offline) throw const TuyaCloudException('brak chmury');
    return states;
  }
}
