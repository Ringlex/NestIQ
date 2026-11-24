import 'dart:async';
import 'dart:io';

/// Wyszukiwanie bramek Mobilus Cosmo GTW w sieci lokalnej.
///
/// Skanuje podsieć /24 każdego prywatnego adresu IPv4 telefonu: najpierw
/// szybka próba połączenia TCP z portem 8884, a dla otwartych portów
/// potwierdzenie, że pod `/mqtt` odpowiada MQTT po WebSocket.
class GatewayDiscovery {
  GatewayDiscovery({
    this.port = 8884,
    this.probeTimeout = const Duration(milliseconds: 600),
    this.verifyTimeout = const Duration(seconds: 3),
    this.concurrency = 48,
  });

  final int port;
  final Duration probeTimeout;
  final Duration verifyTimeout;
  final int concurrency;

  /// Emituje adresy znalezionych bramek; kończy się po sprawdzeniu wszystkich.
  ///
  /// [hosts] zastępuje listę adresów wyznaczoną z interfejsów sieciowych.
  Stream<String> scan({Iterable<String>? hosts}) async* {
    final candidates = (hosts ?? await candidateHosts()).toList();
    final found = StreamController<String>();
    var next = 0;

    Future<void> worker() async {
      while (next < candidates.length) {
        final host = candidates[next++];
        if (await _probe(host) && await _verify(host)) found.add(host);
      }
    }

    final workers = List.generate(
        candidates.isEmpty ? 0 : concurrency.clamp(1, candidates.length),
        (_) => worker());
    unawaited(Future.wait(workers).whenComplete(found.close));
    yield* found.stream;
  }

  /// Adresy do sprawdzenia: sąsiedzi z podsieci /24 telefonu (bez niego samego).
  static Future<List<String>> candidateHosts() async {
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    final own = <String>{};
    final prefixes = <String>{};
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!_isPrivate(addr.rawAddress)) continue;
        own.add(addr.address);
        final b = addr.rawAddress;
        prefixes.add('${b[0]}.${b[1]}.${b[2]}');
      }
    }
    return [
      for (final prefix in prefixes)
        for (var i = 1; i < 255; i++)
          if (!own.contains('$prefix.$i')) '$prefix.$i',
    ];
  }

  static bool _isPrivate(List<int> b) =>
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
      (b[0] == 192 && b[1] == 168);

  Future<bool> _probe(String host) async {
    try {
      final socket = await Socket.connect(host, port, timeout: probeTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _verify(String host) async {
    try {
      final ws =
          await WebSocket.connect('ws://$host:$port/mqtt', protocols: ['mqtt'])
              .timeout(verifyTimeout);
      await ws.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
