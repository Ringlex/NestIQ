import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'tuya_protocol.dart';

/// Łącze z jednym urządzeniem; interfejs, żeby kontroler dało się testować
/// bez gniazd.
abstract interface class TuyaLanLink {
  Stream<Map<String, Object?>> get updates;
  Future<void> get closed;
  bool get isConnected;
  Future<void> connect();
  Future<Map<String, Object?>> queryStatus();
  Future<void> setDps(Map<String, Object?> dps);
  Future<void> close();
}

class TuyaLanException implements Exception {
  const TuyaLanException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Trwałe połączenie TCP z jednym urządzeniem Tuya w sieci lokalnej.
///
/// Urządzenie przyjmuje zwykle jedno połączenie naraz, więc trzymamy je
/// otwarte, a zmiany stanu (także z fizycznego przycisku i aplikacji Tuya)
/// przychodzą jako [updates]. Zerwanie połączenia kończy [closed].
class TuyaLanClient implements TuyaLanLink {
  TuyaLanClient({
    required this.deviceId,
    required String localKey,
    required this.version,
    required this.host,
    this.port = 6668,
    this.connectTimeout = const Duration(seconds: 4),
    this.requestTimeout = const Duration(seconds: 4),
    this.heartbeatInterval = const Duration(seconds: 9),
  }) : _codec =
            TuyaCodec(deviceId: deviceId, localKey: localKey, version: version);

  final String deviceId;
  final String version;
  final String host;
  final int port;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final Duration heartbeatInterval;

  final TuyaCodec _codec;
  Socket? _socket;
  final _buffer = BytesBuilder(copy: false);
  final _waiters = <int, Completer<TuyaFrame>>{};
  final _updates = StreamController<Map<String, Object?>>.broadcast();
  final _closed = Completer<void>();
  Timer? _heartbeat;
  DateTime _lastRx = DateTime.now();
  Future<void> _queue = Future.value();
  bool _isClosed = false;

  /// Zmiany punktów danych: `{"1": true}`.
  @override
  Stream<Map<String, Object?>> get updates => _updates.stream;

  /// Kończy się, gdy połączenie padło albo zostało zamknięte.
  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isConnected => _socket != null && !_isClosed;

  /// Łączy się, negocjuje klucz sesji (3.4/3.5) i uruchamia podtrzymywanie połączenia.
  @override
  Future<void> connect() async {
    try {
      final socket = await Socket.connect(host, port, timeout: connectTimeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      socket.listen(_onData,
          onError: (_) => _shutdown(), onDone: _shutdown, cancelOnError: true);
    } on SocketException catch (e) {
      throw TuyaLanException('Nie można połączyć z $host:$port (${e.message})');
    } on TimeoutException {
      throw TuyaLanException('Urządzenie $host nie odpowiada');
    }

    try {
      if (_codec.needsNegotiation) {
        final response = _expect(TuyaCmd.sessKeyNegResp);
        _socket!.add(_codec.negotiationStart());
        final frame = await _await(response, 'negocjacja klucza');
        _socket!.add(_codec.negotiationFinish(frame));
      }
    } on TuyaProtocolException catch (e) {
      await close();
      throw TuyaLanException(e.message);
    } catch (_) {
      await close();
      rethrow;
    }

    _lastRx = DateTime.now();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) => _beat());
  }

  /// Aktualny stan punktów danych urządzenia.
  @override
  Future<Map<String, Object?>> queryStatus() => _serial(() async {
        final cmd =
            _codec.needsNegotiation ? TuyaCmd.dpQueryNew : TuyaCmd.dpQuery;
        final response = _expect(cmd);
        _send(_codec.buildQuery());
        final frame = await _await(response, 'odczyt stanu');
        return _codec.decodeDps(frame) ?? const {};
      });

  /// Ustawia punkty danych, np. `{"1": true}`. Powodzenie potwierdza ramka
  /// z urządzenia albo push ze zmienionym stanem – zależnie od modelu.
  @override
  Future<void> setDps(Map<String, Object?> dps) => _serial(() async {
        final cmd =
            _codec.needsNegotiation ? TuyaCmd.controlNew : TuyaCmd.control;
        final ack = _expect(cmd);
        final echoed = updates
            .firstWhere((u) => dps.entries.every((e) => u[e.key] == e.value));
        _send(_codec.buildControl(dps));
        try {
          await Future.any<Object?>([ack.future, echoed])
              .timeout(requestTimeout);
        } on TimeoutException {
          _waiters.remove(cmd);
          throw const TuyaLanException('Urządzenie nie potwierdziło polecenia');
        }
      });

  @override
  Future<void> close() async {
    _heartbeat?.cancel();
    final socket = _socket;
    _socket = null;
    _shutdown();
    await socket?.close().catchError((_) => socket);
    socket?.destroy();
  }

  // ---------------------------------------------------------------- wnętrze

  Future<T> _serial<T>(Future<T> Function() action) {
    if (!isConnected)
      return Future.error(
          const TuyaLanException('Brak połączenia z urządzeniem'));
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Completer<TuyaFrame> _expect(int cmd) =>
      _waiters[cmd] = Completer<TuyaFrame>();

  Future<TuyaFrame> _await(Completer<TuyaFrame> waiter, String what) {
    return waiter.future.timeout(requestTimeout, onTimeout: () {
      _waiters.removeWhere((_, w) => identical(w, waiter));
      throw TuyaLanException('Urządzenie nie odpowiedziało ($what)');
    });
  }

  void _send(Uint8List frame) {
    final socket = _socket;
    if (socket == null || _isClosed)
      throw const TuyaLanException('Brak połączenia z urządzeniem');
    socket.add(frame);
  }

  void _beat() {
    if (_isClosed) return;
    if (DateTime.now().difference(_lastRx) > heartbeatInterval * 4) {
      // Urządzenie milczy dłużej niż cztery oddechy – uznajemy połączenie za martwe.
      close();
      return;
    }
    try {
      _send(_codec.buildHeartbeat());
    } on TuyaLanException {
      close();
    }
  }

  void _onData(Uint8List chunk) {
    _lastRx = DateTime.now();
    _buffer.add(chunk);
    var data = _buffer.takeBytes();

    while (true) {
      final length = peekFrameLength(data);
      if (length == null) break;
      if (length < 0) {
        // Rozsynchronizowany strumień: szukamy kolejnego prefiksu ramki.
        final next = _findPrefix(data, 1);
        if (next < 0) {
          data = Uint8List(0);
          break;
        }
        data = Uint8List.sublistView(data, next);
        continue;
      }
      if (data.length < length) break;
      _onFrame(Uint8List.sublistView(data, 0, length));
      data = Uint8List.sublistView(data, length);
    }
    _buffer.add(data);
  }

  int _findPrefix(Uint8List data, int from) {
    for (var i = from; i + 3 < data.length; i++) {
      if (data[i] == 0 &&
          data[i + 1] == 0 &&
          ((data[i + 2] == 0x55 && data[i + 3] == 0xAA) ||
              (data[i + 2] == 0x66 && data[i + 3] == 0x99))) {
        return i;
      }
    }
    return -1;
  }

  void _onFrame(Uint8List bytes) {
    final TuyaFrame frame;
    try {
      frame = _codec.parse(bytes);
    } on TuyaProtocolException {
      return; // Uszkodzona ramka: pomijamy, następna może być dobra.
    }

    final dps = _codec.needsNegotiation && frame.cmd == TuyaCmd.sessKeyNegResp
        ? null
        : _codec.decodeDps(frame);
    if (dps != null && !_updates.isClosed) _updates.add(dps);

    final waiter = _waiters.remove(frame.cmd);
    if (waiter != null && !waiter.isCompleted) waiter.complete(frame);
  }

  void _shutdown() {
    if (_isClosed) return;
    _isClosed = true;
    _heartbeat?.cancel();
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted)
        waiter.completeError(const TuyaLanException('Połączenie zamknięte'));
    }
    _waiters.clear();
    if (!_updates.isClosed) _updates.close();
    if (!_closed.isCompleted) _closed.complete();
  }
}
