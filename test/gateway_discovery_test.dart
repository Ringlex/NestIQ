import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/mobilus/gateway_discovery.dart';

void main() {
  test('znajduje tylko serwer MQTT po WebSocket na /mqtt', () async {
    final gateway = await HttpServer.bind('127.0.0.1', 0);
    gateway.listen((req) async {
      if (req.uri.path != '/mqtt') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req,
          protocolSelector: (p) => p.contains('mqtt') ? 'mqtt' : null);
      ws.listen((_) {});
    });
    // Inna usługa HTTP na tym samym porcie (127.0.0.2) nie jest bramką.
    final other = await HttpServer.bind('127.0.0.2', gateway.port)
        .catchError((_) => gateway);
    if (other != gateway) {
      other.listen((req) async {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });
    }

    final found = await GatewayDiscovery(port: gateway.port)
        .scan(hosts: ['127.0.0.1', '127.0.0.2', '127.0.0.3']).toList();

    expect(found, ['127.0.0.1']);
    await gateway.close(force: true);
    if (other != gateway) await other.close(force: true);
  });

  test('pusta lista adresów kończy skan bez wyników', () async {
    expect(await GatewayDiscovery().scan(hosts: []).toList(), isEmpty);
  });
}
