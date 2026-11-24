import 'package:nestiq/viessmann/viessmann_client.dart';
import 'package:nestiq/viessmann/viessmann_models.dart';
import 'package:nestiq/viessmann/viessmann_store.dart';

import 'fixtures.dart';

// Atrapy wspólne dla testów kontrolera i ekranu Dom.

class MemoryViessmannStore implements ViessmannStore {
  StoredViessmann saved = const StoredViessmann();

  @override
  Future<StoredViessmann> load() async => saved;

  @override
  Future<void> saveSession(
          {required String clientId, required String? refreshToken}) async =>
      saved = StoredViessmann(
          clientId: clientId,
          refreshToken: refreshToken,
          device: saved.device,
          calls: saved.calls);

  @override
  Future<void> saveRefreshToken(String refreshToken) async =>
      saved = StoredViessmann(
          clientId: saved.clientId,
          refreshToken: refreshToken,
          device: saved.device,
          calls: saved.calls);

  @override
  Future<void> saveDevice(ViessmannDeviceRef device) async =>
      saved = StoredViessmann(
          clientId: saved.clientId,
          refreshToken: saved.refreshToken,
          device: device,
          calls: saved.calls);

  @override
  Future<void> saveCalls(List<int> calls) async => saved = StoredViessmann(
      clientId: saved.clientId,
      refreshToken: saved.refreshToken,
      device: saved.device,
      calls: [...calls]);

  @override
  Future<void> clear() async => saved = const StoredViessmann();
}

/// Atrapa API na poziomie interfejsu: zapisuje polecenia i oddaje ustawiony stan pieca.
class FakeViessmannApi implements ViessmannApi {
  FakeViessmannApi(this.onCall);

  final void Function() onCall;
  var featureCalls = 0;
  var data = vitodensFeatures();
  final executed = <(String, String, Map<String, Object?>)>[];
  ViessmannException? failWith;

  @override
  Future<ViessmannDeviceRef> findHeatingDevice() async {
    onCall();
    return testDevice;
  }

  @override
  Future<List<Map<String, dynamic>>> features(ViessmannDeviceRef ref) async {
    onCall();
    featureCalls++;
    if (failWith != null) throw failWith!;
    return data;
  }

  @override
  Future<void> execute(
      ViessmannDeviceRef ref, FeatureCommand command, Map<String, Object?> body,
      {String? feature}) async {
    onCall();
    executed.add((feature ?? '', command.name, body));
    if (command.name == 'setTemperature') {
      data = vitodensFeatures(
          circuitTemperature: body['targetTemperature']! as num);
    } else if (command.name == 'setTargetTemperature') {
      data = vitodensFeatures(dhwTarget: body['temperature']! as num);
    } else if (feature == HeatingState.dhwModeFeature) {
      data = vitodensFeatures(dhwMode: body['mode']! as String);
    } else if (feature == HeatingState.heatingModeFeature) {
      data = vitodensFeatures(heatingMode: body['mode']! as String);
    }
  }
}
