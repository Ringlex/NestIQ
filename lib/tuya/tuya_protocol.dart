import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart';

/// Protokół LAN Tuya, wersje 3.3, 3.4 i 3.5 (TCP :6668).
///
/// Opis na podstawie referencyjnej biblioteki tinytuya; zgodność z nią jest
/// sprawdzana bajt w bajt w `test/tuya/` na ramkach wygenerowanych przez nią.
///
/// - 3.3: ramka `55AA`, AES-128-ECB kluczem urządzenia, suma CRC32.
/// - 3.4: ramka `55AA`, klucz sesji z negocjacji, AES-ECB, suma HMAC-SHA256.
/// - 3.5: ramka `6699`, klucz sesji z negocjacji, AES-GCM.
class TuyaCmd {
  static const sessKeyNegStart = 3;
  static const sessKeyNegResp = 4;
  static const sessKeyNegFinish = 5;
  static const control = 7;
  static const status = 8;
  static const heartBeat = 9;
  static const dpQuery = 0x0a;
  static const controlNew = 0x0d;
  static const dpQueryNew = 0x10;
}

const _prefix55AA = 0x000055AA;
const _suffix55AA = 0x0000AA55;
const _prefix6699 = 0x00006699;
const _suffix6699 = 0x00009966;

/// Ramka po rozpakowaniu; [payload] jest już odszyfrowany tylko dla ramek 6699.
class TuyaFrame {
  const TuyaFrame({
    required this.seqno,
    required this.cmd,
    required this.payload,
    this.retcode,
    this.is6699 = false,
  });

  final int seqno;
  final int cmd;
  final int? retcode;
  final Uint8List payload;
  final bool is6699;
}

class TuyaProtocolException implements Exception {
  const TuyaProtocolException(this.message);
  final String message;

  @override
  String toString() => 'TuyaProtocolException: $message';
}

// ---------------------------------------------------------------- krypto

Uint8List _pkcs7Pad(Uint8List data) {
  final pad = 16 - data.length % 16;
  return Uint8List.fromList([...data, ...List.filled(pad, pad)]);
}

Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) throw const TuyaProtocolException('pusty blok');
  final pad = data.last;
  if (pad < 1 || pad > 16 || pad > data.length) {
    throw const TuyaProtocolException('zły padding');
  }
  return Uint8List.sublistView(data, 0, data.length - pad);
}

Uint8List _ecb(Uint8List key, Uint8List data, {required bool encrypt}) {
  if (data.length % 16 != 0)
    throw const TuyaProtocolException('długość nie jest wielokrotnością 16');
  final cipher = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    cipher.processBlock(data, i, out, i);
  }
  return out;
}

/// AES-128-ECB z paddingiem PKCS7 (domyślnie), jak w ramkach 3.3 i 3.4.
Uint8List aesEcbEncrypt(Uint8List key, Uint8List data, {bool pad = true}) =>
    _ecb(key, pad ? _pkcs7Pad(data) : data, encrypt: true);

Uint8List aesEcbDecrypt(Uint8List key, Uint8List data, {bool unpad = true}) {
  final plain = _ecb(key, data, encrypt: false);
  return unpad ? _pkcs7Unpad(plain) : plain;
}

/// AES-GCM; wynik to `szyfrogram || tag(16)`.
Uint8List aesGcmEncrypt(
    Uint8List key, Uint8List iv, Uint8List data, Uint8List aad) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, iv, aad));
  return cipher.process(data);
}

/// Wejście: `szyfrogram || tag`. Zła etykieta rzuca [TuyaProtocolException].
Uint8List aesGcmDecrypt(
    Uint8List key, Uint8List iv, Uint8List data, Uint8List aad) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), 128, iv, aad));
  try {
    return cipher.process(data);
  } on InvalidCipherTextException {
    throw const TuyaProtocolException('GCM: zła etykieta uwierzytelniająca');
  }
}

Uint8List hmacSha256(Uint8List key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

final _crcTable = () {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Klucz szyfrujący rozgłoszenia UDP: MD5("yGAdlopoPVldABfn").
final Uint8List udpKey =
    Uint8List.fromList(md5.convert(utf8.encode('yGAdlopoPVldABfn')).bytes);

// ---------------------------------------------------------------- ramki

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

/// Ramka `55AA`. Z [hmacKey] suma kontrolna to HMAC-SHA256 (3.4), bez – CRC32 (3.3).
/// [retcode] dopisuje się tylko w ramkach urządzenie → klient (testy).
Uint8List pack55AA(int seqno, int cmd, Uint8List payload,
    {Uint8List? hmacKey, int? retcode}) {
  final body = retcode == null
      ? payload
      : Uint8List.fromList([..._u32(retcode), ...payload]);
  final endLen = hmacKey != null ? 36 : 8;
  final out = BytesBuilder()
    ..add(_u32(_prefix55AA))
    ..add(_u32(seqno))
    ..add(_u32(cmd))
    ..add(_u32(body.length + endLen))
    ..add(body);
  final head = out.toBytes();
  if (hmacKey != null) {
    out.add(hmacSha256(hmacKey, head));
  } else {
    out.add(_u32(crc32(head)));
  }
  out.add(_u32(_suffix55AA));
  return out.toBytes();
}

/// Ramka `6699` (3.5): AES-GCM, nagłówek (bez prefiksu) jest danymi uwierzytelnianymi.
Uint8List pack6699(
    int seqno, int cmd, Uint8List payload, Uint8List key, Uint8List iv,
    {int? retcode}) {
  final plain = retcode == null
      ? payload
      : Uint8List.fromList([..._u32(retcode), ...payload]);
  final length = plain.length + 16 + 12;
  final header = BytesBuilder()
    ..add(_u32(_prefix6699))
    ..add(Uint8List(2))
    ..add(_u32(seqno))
    ..add(_u32(cmd))
    ..add(_u32(length));
  final head = header.toBytes();
  final sealed = aesGcmEncrypt(key, iv, plain, Uint8List.sublistView(head, 4));
  return Uint8List.fromList([...head, ...iv, ...sealed, ..._u32(_suffix6699)]);
}

/// Ile bajtów ma pierwsza ramka w [buffer]: `null` – za mało danych na nagłówek,
/// `-1` – bufor nie zaczyna się prefiksem ramki.
int? peekFrameLength(Uint8List buffer) {
  if (buffer.length < 4) return null;
  final view = ByteData.sublistView(buffer);
  final prefix = view.getUint32(0);
  if (prefix == _prefix55AA) {
    if (buffer.length < 16) return null;
    return 16 + view.getUint32(12);
  }
  if (prefix == _prefix6699) {
    if (buffer.length < 18) return null;
    return 18 + view.getUint32(14) + 4;
  }
  return -1;
}

/// Rozpakowuje jedną pełną ramkę. [hasRetcode] – ramki z urządzenia zaczynają się
/// od 4-bajtowego kodu wyniku. Zła suma kontrolna albo etykieta GCM rzuca wyjątek.
TuyaFrame unpackFrame(Uint8List data,
    {Uint8List? key, bool hmac = false, bool hasRetcode = true}) {
  final view = ByteData.sublistView(data);
  final prefix = view.getUint32(0);

  if (prefix == _prefix55AA) {
    final length = view.getUint32(12);
    if (data.length < 16 + length)
      throw const TuyaProtocolException('ucięta ramka');
    final endLen = hmac ? 36 : 8;
    final retLen = hasRetcode ? 4 : 0;
    if (length < retLen + endLen)
      throw const TuyaProtocolException('za krótka ramka');
    final signedEnd = 16 + length - endLen;
    final expected = hmac
        ? hmacSha256(key!, Uint8List.sublistView(data, 0, signedEnd))
        : _u32(crc32(Uint8List.sublistView(data, 0, signedEnd)));
    final actual =
        Uint8List.sublistView(data, signedEnd, signedEnd + (hmac ? 32 : 4));
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ actual[i];
    }
    if (diff != 0) throw const TuyaProtocolException('zła suma kontrolna');
    return TuyaFrame(
      seqno: view.getUint32(4),
      cmd: view.getUint32(8),
      retcode: hasRetcode ? view.getUint32(16) : null,
      payload: Uint8List.fromList(data.sublist(16 + retLen, signedEnd)),
    );
  }

  if (prefix == _prefix6699) {
    final length = view.getUint32(14);
    if (data.length < 18 + length + 4)
      throw const TuyaProtocolException('ucięta ramka');
    if (length < 12 + 16) throw const TuyaProtocolException('za krótka ramka');
    final iv = Uint8List.sublistView(data, 18, 30);
    final sealed = Uint8List.sublistView(data, 30, 18 + length);
    final plain =
        aesGcmDecrypt(key!, iv, sealed, Uint8List.sublistView(data, 4, 18));
    final retLen = hasRetcode && plain.length >= 4 ? 4 : 0;
    return TuyaFrame(
      seqno: view.getUint32(6),
      cmd: view.getUint32(10),
      retcode: retLen == 4 ? ByteData.sublistView(plain).getUint32(0) : null,
      payload: Uint8List.fromList(plain.sublist(retLen)),
      is6699: true,
    );
  }

  throw const TuyaProtocolException('nieznany prefiks ramki');
}

// ---------------------------------------------------------------- kodek

/// Stan protokołu jednego urządzenia: budowanie żądań, negocjacja klucza sesji
/// (3.4/3.5) i dekodowanie odpowiedzi. Bez wejścia/wyjścia, więc da się go
/// testować bajt w bajt. [clock], [nonce] i [iv] można podmienić w testach.
class TuyaCodec {
  TuyaCodec({
    required this.deviceId,
    required String localKey,
    required this.version,
    int Function()? clock,
    Uint8List Function(int length)? random,
  })  : _realKey = Uint8List.fromList(utf8.encode(localKey)),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
        _random = random ?? _secureRandom {
    if (!const {'3.3', '3.4', '3.5'}.contains(version)) {
      throw TuyaProtocolException('Nieobsługiwana wersja protokołu: $version');
    }
    if (_realKey.length != 16)
      throw const TuyaProtocolException('Klucz lokalny musi mieć 16 znaków');
    _sessionKey = _realKey;
  }

  final String deviceId;
  final String version;
  final Uint8List _realKey;
  final int Function() _clock;
  final Uint8List Function(int) _random;
  late Uint8List _sessionKey;
  Uint8List _localNonce = Uint8List(16);
  int _seqno = 1;

  static final _rng = Random.secure();
  static Uint8List _secureRandom(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  @visibleForTesting
  Uint8List get sessionKey => _sessionKey;

  bool get needsNegotiation => version != '3.3';
  bool get _is35 => version == '3.5';
  bool get _isNew => version != '3.3';

  /// `3.x` + 12 zer, doklejane do poleceń sterujących.
  Uint8List get _versionHeader =>
      Uint8List.fromList([...utf8.encode(version), ...List.filled(12, 0)]);

  Uint8List _json(Map<String, Object?> body) =>
      Uint8List.fromList(utf8.encode(jsonEncode(body)));

  Uint8List _frame(int cmd, Uint8List plain, {bool withHeader = false}) {
    final payload =
        withHeader ? Uint8List.fromList([..._versionHeader, ...plain]) : plain;
    final seq = _seqno++;
    if (_is35) {
      return pack6699(seq, cmd, payload, _sessionKey, _random(12));
    }
    if (version == '3.4') {
      return pack55AA(seq, cmd, aesEcbEncrypt(_sessionKey, payload),
          hmacKey: _sessionKey);
    }
    // 3.3: nagłówek wersji jest poza szyfrogramem.
    final encrypted = aesEcbEncrypt(_sessionKey, plain);
    return pack55AA(
        seq,
        cmd,
        withHeader
            ? Uint8List.fromList([..._versionHeader, ...encrypted])
            : encrypted);
  }

  // ---- negocjacja klucza sesji (3.4 i 3.5)

  /// Krok 1: wysyłamy własny nonce zaszyfrowany kluczem urządzenia.
  Uint8List negotiationStart() {
    _sessionKey = _realKey;
    _localNonce = _random(16);
    return _frame(TuyaCmd.sessKeyNegStart, _localNonce);
  }

  /// Krok 3: sprawdza odpowiedź urządzenia, wylicza klucz sesji i zwraca ramkę
  /// kończącą negocjację. Zły HMAC oznacza zły klucz lokalny.
  Uint8List negotiationFinish(TuyaFrame response) {
    if (response.cmd != TuyaCmd.sessKeyNegResp) {
      throw const TuyaProtocolException('Zła odpowiedź na negocjację klucza');
    }
    var payload = response.payload;
    if (version == '3.4') payload = aesEcbDecrypt(_realKey, payload);
    if (payload.length < 48)
      throw const TuyaProtocolException('Za krótka odpowiedź negocjacji');

    final remoteNonce = Uint8List.sublistView(payload, 0, 16);
    final expected = hmacSha256(_realKey, _localNonce);
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= expected[i] ^ payload[16 + i];
    }
    if (diff != 0) {
      throw const TuyaProtocolException(
          'Negocjacja klucza odrzucona: sprawdź klucz lokalny urządzenia');
    }

    final proof = hmacSha256(_realKey, remoteNonce);
    final finish = _frame(TuyaCmd.sessKeyNegFinish, proof);

    final mixed = Uint8List.fromList(
        [for (var i = 0; i < 16; i++) _localNonce[i] ^ remoteNonce[i]]);
    _sessionKey = _is35
        ? Uint8List.fromList(aesGcmEncrypt(_realKey,
                Uint8List.sublistView(_localNonce, 0, 12), mixed, Uint8List(0))
            .sublist(0, 16))
        : aesEcbEncrypt(_realKey, mixed, pad: false);
    return finish;
  }

  // ---- polecenia

  Uint8List buildQuery() {
    if (_isNew) return _frame(TuyaCmd.dpQueryNew, _json({}));
    return _frame(
        TuyaCmd.dpQuery,
        _json({
          'gwId': deviceId,
          'devId': deviceId,
          'uid': deviceId,
          't': '${_clock()}'
        }));
  }

  Uint8List buildControl(Map<String, Object?> dps) {
    if (_isNew) {
      return _frame(
        TuyaCmd.controlNew,
        _json({
          'protocol': 5,
          't': _clock(),
          'data': {'dps': dps},
        }),
        withHeader: true,
      );
    }
    return _frame(
      TuyaCmd.control,
      _json(
          {'devId': deviceId, 'uid': deviceId, 't': '${_clock()}', 'dps': dps}),
      withHeader: true,
    );
  }

  Uint8List buildHeartbeat() =>
      _frame(TuyaCmd.heartBeat, _json({'gwId': deviceId, 'devId': deviceId}));

  // ---- odpowiedzi

  /// Rozpakowuje ramkę z urządzenia. 3.4 używa HMAC klucza sesji, 3.5 – GCM.
  TuyaFrame parse(Uint8List data) =>
      unpackFrame(data, key: _sessionKey, hmac: version == '3.4');

  /// Punkty danych z ramki (status, odpowiedź na zapytanie) albo `null`, gdy
  /// ramka ich nie niesie (np. potwierdzenie polecenia).
  Map<String, Object?>? decodeDps(TuyaFrame frame) {
    final json = decodeJson(frame);
    if (json == null) return null;
    final dps = json['dps'] ??
        (json['data'] is Map ? (json['data'] as Map)['dps'] : null);
    return dps is Map ? dps.cast<String, Object?>() : null;
  }

  Map<String, Object?>? decodeJson(TuyaFrame frame) {
    var payload = frame.payload;
    if (payload.isEmpty) return null;
    try {
      if (version == '3.3') {
        if (_startsWithVersion(payload))
          payload = Uint8List.sublistView(payload, 15);
        if (payload.isEmpty) return null;
        payload = aesEcbDecrypt(_sessionKey, payload);
      } else if (version == '3.4') {
        payload = aesEcbDecrypt(_sessionKey, payload);
        if (_startsWithVersion(payload))
          payload = Uint8List.sublistView(payload, 15);
      } else if (_startsWithVersion(payload)) {
        payload = Uint8List.sublistView(payload, 15);
      }
      final decoded = jsonDecode(utf8.decode(payload, allowMalformed: true));
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on TuyaProtocolException {
      return null;
    } on FormatException {
      // Np. „json obj data unvalid” z urządzeń, które nie rozumieją zapytania.
      return null;
    }
  }

  bool _startsWithVersion(Uint8List p) =>
      p.length >= 15 &&
      p[0] == 0x33 &&
      p[1] == 0x2e &&
      p[2] == utf8.encode(version)[2];
}
