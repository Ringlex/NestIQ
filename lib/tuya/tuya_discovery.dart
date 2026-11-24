import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'tuya_models.dart';
import 'tuya_protocol.dart';

/// Wykrywanie włączników Tuya w sieci lokalnej po rozgłoszeniach UDP.
///
/// Urządzenia 3.1–3.4 same rozgłaszają się na portach 6666/6667. Starsze
/// 3.5 milczą, dopóki aplikacja nie wyśle zapytania na port 7000.
class TuyaDiscovery {
  /// Rozpakowuje datagram rozgłoszeniowy; `null`, gdy to nie ramka Tuya
  /// albo nie niesie adresu i identyfikatora.
  static TuyaDiscovered? parseBroadcast(Uint8List datagram) {
    try {
      final String text;
      final prefix = datagram.length >= 4
          ? ByteData.sublistView(datagram).getUint32(0)
          : 0;
      if (prefix == 0x000055AA) {
        final payload = unpackFrame(datagram).payload;
        text = payload.isNotEmpty && payload.first == 0x7b
            ? utf8.decode(payload, allowMalformed: true)
            : utf8.decode(aesEcbDecrypt(udpKey, payload), allowMalformed: true);
      } else if (prefix == 0x00006699) {
        var payload =
            unpackFrame(datagram, key: udpKey, hasRetcode: false).payload;
        // Kod wyniku bywa dopisany przed JSON-em.
        if (payload.length > 4 && payload[0] != 0x7b && payload[4] == 0x7b) {
          payload = Uint8List.sublistView(payload, 4);
        }
        text =
            utf8.decode(payload, allowMalformed: true).replaceAll('\u0000', '');
      } else {
        return null;
      }

      final json = jsonDecode(text);
      if (json is! Map) return null;
      final id = (json['gwId'] ?? json['devId']) as String?;
      final ip = json['ip'] as String?;
      if (id == null || ip == null) return null;
      return TuyaDiscovered(
          id: id, ip: ip, version: json['version']?.toString());
    } on TuyaProtocolException {
      return null;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  /// Zapytanie, na które odpowiadają urządzenia 3.5 (port 7000).
  static Uint8List buildRequest(String ownIp, {Uint8List? iv}) {
    final payload = Uint8List.fromList(
        utf8.encode(jsonEncode({'from': 'app', 'ip': ownIp})));
    final nonce = iv ??
        Uint8List.fromList(
            List.generate(12, (_) => Random.secure().nextInt(256)));
    return pack6699(0, 0x25, payload, udpKey, nonce);
  }

  /// Nasłuchuje [timeout] i zwraca znalezione urządzenia (bez powtórzeń).
  static Future<List<TuyaDiscovered>> scan(
      {Duration timeout = const Duration(seconds: 7)}) async {
    final found = <String, TuyaDiscovered>{};
    final sockets = <RawDatagramSocket>[];

    for (final port in const [6666, 6667]) {
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
          // SO_REUSEPORT nie jest dostępny na Androidzie ani w Windows.
          reusePort: Platform.isIOS || Platform.isMacOS || Platform.isLinux,
        );
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          final device = parseBroadcast(datagram.data);
          if (device != null) found[device.id] = device;
        });
        sockets.add(socket);
      } on SocketException {
        // Port zajęty albo brak uprawnień – szukamy tym, co się uda.
      }
    }

    await _requestV35();
    await Future<void>.delayed(timeout);
    for (final socket in sockets) {
      socket.close();
    }
    return found.values.toList();
  }

  static Future<void> _requestV35() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          final socket = await RawDatagramSocket.bind(address, 0);
          socket.broadcastEnabled = true;
          final request = buildRequest(address.address);
          final octets = address.address.split('.');
          // Brak maski podsieci w Dart: zakładamy /24, a rozgłoszenie ogólne jako zapas.
          for (final target in [
            '${octets.take(3).join('.')}.255',
            '255.255.255.255'
          ]) {
            socket.send(request, InternetAddress(target), 7000);
          }
          socket.close();
        }
      }
    } on SocketException {
      // Brak interfejsu lub zakaz rozgłaszania: urządzenia 3.3/3.4 i tak się odezwą.
    }
  }
}
