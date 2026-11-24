// Ramka wiadomości bramki Mobilus:
//
//   uint32 length (=13) | uint8 category | uint32 timestamp |
//   6 B client id | uint8 platform | uint8 response code | body
//
// Body to protobuf, szyfrowany AES-CFB128 z IV = 12 × 0x00 + timestamp (BE).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'proto.dart';

const _headerSize = 17;
const _headerLength = 13;
const _platformMobile = 4;

/// Klucze sesji: klucz użytkownika (SHA-256 hasła) oraz klucze z LoginResponse.
class KeyRing {
  KeyRing(String password) : userKey = createKey(password);

  final Uint8List userKey;
  Uint8List? privateKey;
  Uint8List? publicKey;

  void register(LoginResponse response) {
    privateKey = response.privateKey;
    publicKey = response.publicKey;
  }

  /// Bramka oczekuje szyfrowania dla komend sterujących i zapisu scen.
  Uint8List? encryptionKeyFor(MobilusMessage message) =>
      message is CallEventsRequest || message is SceneEditRequest
          ? privateKey
          : null;

  Uint8List? decryptionKeyFor(int category) => switch (category) {
        MobilusCodec.loginResponse => userKey,
        MobilusCodec.callEvents => publicKey,
        _ => privateKey,
      };
}

Uint8List createKey(String password) =>
    Uint8List.fromList(sha256.convert(utf8.encode(password)).bytes);

Uint8List createIv(int timestamp) {
  final iv = Uint8List(16);
  ByteData.sublistView(iv).setUint32(12, timestamp, Endian.big);
  return iv;
}

/// AES w trybie CFB z 128-bitowym segmentem (jak `cryptography` w Pythonie).
Uint8List aesCfb(Uint8List key, Uint8List iv, Uint8List input,
    {required bool encrypt}) {
  final cipher = CFBBlockCipher(AESEngine(), 16)
    ..init(encrypt, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(input.length);
  final block = Uint8List(16);
  final outBlock = Uint8List(16);
  for (var offset = 0; offset < input.length; offset += 16) {
    final n = (input.length - offset).clamp(0, 16);
    block.fillRange(0, 16, 0);
    block.setRange(0, n, input, offset);
    cipher.processBlock(block, 0, outBlock, 0);
    out.setRange(offset, offset + n, outBlock);
  }
  return out;
}

class MobilusCodec {
  static const loginRequest = 1;
  static const loginResponse = 2;
  static const devicesListRequest = 3;
  static const devicesListResponse = 4;
  static const scenesListRequest = 9;
  static const scenesListResponse = 10;
  static const sceneEditRequest = 16;
  static const sceneEditResponse = 17;
  static const callEvents = 13;
  static const currentStateRequest = 26;
  static const currentStateResponse = 27;

  static int categoryOf(MobilusMessage message) => switch (message) {
        LoginRequest() => loginRequest,
        LoginResponse() => loginResponse,
        DevicesListRequest() => devicesListRequest,
        DevicesListResponse() => devicesListResponse,
        ScenesListRequest() => scenesListRequest,
        ScenesListResponse() => scenesListResponse,
        SceneEditRequest() => sceneEditRequest,
        SceneEditResponse() => sceneEditResponse,
        CallEventsRequest() => callEvents,
        CurrentStateRequest() => currentStateRequest,
        CurrentStateResponse() => currentStateResponse,
      };

  static Uint8List encode(
    MobilusMessage message, {
    required String clientId,
    required KeyRing keys,
    int? timestamp,
  }) {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var body = message.encode();
    final key = keys.encryptionKeyFor(message);
    if (key != null) {
      body = aesCfb(key, createIv(ts), body, encrypt: true);
    }

    final header = ByteData(_headerSize)
      ..setUint32(0, _headerLength)
      ..setUint8(4, categoryOf(message))
      ..setUint32(5, ts);
    final id = _hexToBytes(clientId);
    for (var i = 0; i < 6; i++) {
      header.setUint8(9 + i, id[i]);
    }
    header
      ..setUint8(15, _platformMobile)
      ..setUint8(16, 0);

    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(body))
        .toBytes();
  }

  /// Zwraca `null`, gdy wiadomość jest nieznana albo nie da się jej odszyfrować.
  static MobilusMessage? decode(Uint8List frame, KeyRing keys) {
    if (frame.length < _headerSize) return null;
    final header = ByteData.sublistView(frame, 0, _headerSize);
    final category = header.getUint8(4);
    final timestamp = header.getUint32(5);

    final key = keys.decryptionKeyFor(category);
    if (key == null || key.isEmpty) return null;

    final body = aesCfb(
      key,
      createIv(timestamp),
      Uint8List.sublistView(frame, _headerSize),
      encrypt: false,
    );

    try {
      return switch (category) {
        loginResponse => LoginResponse.decode(body),
        devicesListResponse => DevicesListResponse.decode(body),
        scenesListResponse => ScenesListResponse.decode(body),
        sceneEditResponse => SceneEditResponse.decode(body),
        callEvents => CallEventsRequest.decode(body),
        currentStateResponse => CurrentStateResponse.decode(body),
        _ => null,
      };
    } on FormatException {
      // Odpowiedź na logowanie, której nie da się odczytać kluczem z hasła,
      // oznacza błędne dane logowania – nie czekamy na timeout.
      return category == loginResponse
          ? const LoginResponse(loginStatus: 1)
          : null;
    }
  }

  static Uint8List _hexToBytes(String hex) => Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
}
