// Wektory testowe wygenerowane referencyjną biblioteką Pythona mobilus-client.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/mobilus/codec.dart';
import 'package:nestiq/mobilus/device_info.dart';
import 'package:nestiq/mobilus/proto.dart';

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  const clientId = '0A1B2C3D4E5F';

  KeyRing loggedInKeys() => KeyRing('secret')
    ..privateKey = Uint8List.fromList(List.generate(32, (i) => i))
    ..publicKey = Uint8List.fromList(List.generate(32, (i) => i + 32));

  test('klucz użytkownika to SHA-256 hasła', () {
    expect(toHex(createKey('secret')),
        '2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b');
  });

  test('AES-CFB zgodny z OpenSSL (aes-256-cfb)', () {
    final out = aesCfb(
      createKey('secret'),
      hex('000000000000000000000000665a1f00'),
      Uint8List.fromList('hello mobilus gateway!!'.codeUnits),
      encrypt: true,
    );
    expect(toHex(out), '4d92b62df92e0aa36c2adcba2a2704a85e1a8653efe11f');
  });

  test('ramka logowania', () {
    final frame = MobilusCodec.encode(
      LoginRequest(login: 'admin', password: createKey('secret')),
      clientId: clientId,
      keys: KeyRing('secret'),
      timestamp: 1717171717,
    );
    expect(
        toHex(frame),
        '0000000d016659f6050a1b2c3d4e5f04000a0561646d696e1220'
        '2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b');
  });

  test('zaszyfrowana komenda sterująca', () {
    final frame = MobilusCodec.encode(
      const CallEventsRequest(
          [DeviceEvent(deviceId: 3, eventNumber: 6, value: '45%')]),
      clientId: clientId,
      keys: loggedInKeys(),
      timestamp: 1717171717,
    );
    expect(toHex(frame),
        '0000000d0d6659f6050a1b2c3d4e5f0400a4d1de845489a6f44fc170');
  });

  test('odszyfrowanie LoginResponse', () {
    final msg = MobilusCodec.decode(
      hex('0000000d026659f6060a1b2c3d4e5f0400043554542590e34b501c247dd789cfbbe0389f9c488846'
          'af309a4b96bee18872294d1d7eaccec33c116ab18840e7338eb7a6c28788d1d16a173f0d409ae442'
          '3c9719962dc8477dbcfc11fadcdf609ff3'),
      KeyRing('secret'),
    );
    expect(msg, isA<LoginResponse>());
    final r = msg! as LoginResponse;
    expect(r.isAuthenticated, isTrue);
    expect(r.serialNumber, 'GTW123');
    expect(r.userId, 7);
    expect(r.privateKey, List.generate(32, (i) => i));
    expect(r.publicKey, List.generate(32, (i) => i + 32));
  });

  test('odszyfrowanie listy urządzeń', () {
    final msg = MobilusCodec.decode(
      hex('0000000d046659f6060a1b2c3d4e5f0400a3841c679ce27b6c01286d9a300fec3db703e746169b7b'
          '235aa3c848f82af5f908fbacf232fa763b'),
      loggedInKeys(),
    ) as DevicesListResponse;
    expect(msg.devices.map((d) => (d.id, d.name, d.type, d.favourite)), [
      (3, 'Salon', 2, true),
      (12, 'Kuchnia łazienka', 1, false),
    ]);
  });

  test('round-trip zdarzenia przez kanał publiczny', () {
    final keys = loggedInKeys()..privateKey = loggedInKeys().publicKey;
    final frame = MobilusCodec.encode(
      const CallEventsRequest(
          [DeviceEvent(deviceId: 9, eventNumber: 8, value: 'DOWN:60\$')]),
      clientId: clientId,
      keys: keys,
    );
    final decoded =
        MobilusCodec.decode(frame, loggedInKeys()) as CallEventsRequest;
    expect(decoded.events.single.deviceId, 9);
    expect(decoded.events.single.value, 'DOWN:60\$');
  });

  group('DeviceStatus', () {
    DeviceStatus s(String v, [int ev = 8]) =>
        DeviceStatus(DeviceEvent(deviceId: 1, eventNumber: ev, value: v));

    test('pozycje', () {
      expect(s('UP').position, 100);
      expect(s('DOWN').position, 0);
      expect(s('45%').position, 45);
      expect(s('STOP').position, isNull);
      expect(s('30%:60\$').tilt, 60);
      expect(s('30%:60\$', 7).position, 60);
      expect(s('ON').isOn, isTrue);
    });
  });
}
