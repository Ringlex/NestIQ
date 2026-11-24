// Test na żywo: wymaga działającej bramki lub atrapy (tool/fake_gateway).
//   flutter test test/integration --dart-define=GW_HOST=127.0.0.1 \
//     --dart-define=GW_LOGIN=admin --dart-define=GW_PASSWORD=secret
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/mobilus/mobilus_client.dart';

const host = String.fromEnvironment('GW_HOST');
const login = String.fromEnvironment('GW_LOGIN', defaultValue: 'admin');
const password = String.fromEnvironment('GW_PASSWORD');

void main() {
  test('logowanie, lista urządzeń, stan i komenda', () async {
    final client = MobilusClient(host: host, login: login, password: password);
    final session = await client.connect();
    expect(session.isAuthenticated, isTrue);

    final devices = await client.devicesList();
    expect(devices, isNotEmpty);
    // ignore: avoid_print
    print(
        'Urządzenia: ${devices.map((d) => '${d.id}:${d.name}(${d.type})').join(', ')}');

    final state = await client.currentState();
    // ignore: avoid_print
    print('Stan: ${state.map((e) => '${e.deviceId}=${e.value}').join(', ')}');

    if (const bool.fromEnvironment('GW_SEND_COMMAND')) {
      final echo = client.events.first.timeout(const Duration(seconds: 10));
      client.callEvent(devices.first.id, 'STOP');
      expect((await echo).deviceId, devices.first.id);
    }
    await client.dispose();
  }, skip: host.isEmpty ? 'Podaj --dart-define=GW_HOST=...' : false);

  test('złe hasło jest odrzucane', () async {
    final client =
        MobilusClient(host: host, login: login, password: 'zle-haslo');
    await expectLater(client.connect(), throwsA(isA<MobilusException>()));
  }, skip: host.isEmpty ? 'Podaj --dart-define=GW_HOST=...' : false);
}
