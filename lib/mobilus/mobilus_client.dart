import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_buffers.dart';

import 'codec.dart';
import 'proto.dart';

class MobilusException implements Exception {
  const MobilusException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Połączenie z bramką Mobilus Cosmo GTW przez MQTT po WebSocket (port 8884).
///
/// Bramka nasłuchuje komend na temacie `module`, a odpowiada na temat
/// równy identyfikatorowi klienta oraz rozgłasza zmiany na temacie `clients`.
class MobilusClient {
  MobilusClient({
    required this.host,
    required this.login,
    required String password,
    this.port = 8884,
    this.timeout = const Duration(seconds: 15),
  })  : _keys = KeyRing(password),
        clientId = _randomClientId();

  static const _commandTopic = 'module';
  static const _sharedTopic = 'clients';

  final String host;
  final int port;
  final String login;
  final Duration timeout;
  final String clientId;
  final KeyRing _keys;

  MqttServerClient? _mqtt;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;
  final _incoming = StreamController<MobilusMessage>.broadcast();
  final _events = StreamController<DeviceEvent>.broadcast();
  final _disconnected = StreamController<void>.broadcast();

  LoginResponse? session;

  /// Zmiany stanu urządzeń zgłaszane przez bramkę (również z pilotów i innych aplikacji).
  Stream<DeviceEvent> get events => _events.stream;

  /// Emituje, gdy połączenie z bramką zostanie zerwane.
  Stream<void> get disconnected => _disconnected.stream;

  bool get isConnected =>
      _mqtt?.connectionStatus?.state == MqttConnectionState.connected &&
      session != null;

  Future<LoginResponse> connect() async {
    final mqtt = MqttServerClient.withPort('ws://$host/mqtt', clientId, port)
      ..useWebSocket = true
      ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
      ..setProtocolV311()
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 5000
      ..logging(on: false)
      ..connectionMessage =
          MqttConnectMessage().withClientIdentifier(clientId).startClean();
    mqtt.onDisconnected = () => _disconnected.add(null);
    _mqtt = mqtt;

    try {
      await mqtt.connect().timeout(timeout);
    } catch (e) {
      mqtt.disconnect();
      throw MobilusException(
          'Nie udało się połączyć z bramką $host:$port ($e)');
    }
    if (mqtt.connectionStatus?.state != MqttConnectionState.connected) {
      mqtt.disconnect();
      throw MobilusException(
          'Bramka odrzuciła połączenie MQTT (${mqtt.connectionStatus})');
    }

    _updatesSub = mqtt.updates?.listen(_onMqttMessages);

    await _subscribe([clientId, _sharedTopic]);

    final loginFuture = _expect<LoginResponse>();
    _publish(LoginRequest(login: login, password: _keys.userKey));

    final LoginResponse response;
    try {
      response = await loginFuture;
    } on TimeoutException {
      await dispose();
      throw const MobilusException('Bramka nie odpowiedziała na logowanie');
    }

    if (!response.isAuthenticated) {
      await dispose();
      throw const MobilusException('Nieprawidłowy login lub hasło');
    }
    _keys.register(response);
    session = response;
    return response;
  }

  Future<List<Device>> devicesList() async {
    final future = _expect<DevicesListResponse>();
    _publish(const DevicesListRequest());
    return (await future).devices;
  }

  /// Sceny zapisane w bramce dla zalogowanego użytkownika.
  Future<List<GatewayScene>> scenesList() async {
    final future = _expect<ScenesListResponse>();
    _publish(const ScenesListRequest());
    return (await future).scenes;
  }

  /// Dodaje scenę (id = 0) albo zapisuje zmiany istniejącej.
  Future<void> saveScene(GatewayScene scene) =>
      _editScene(SceneEditRequest(scene));

  Future<void> removeScene(int id) => _editScene(SceneEditRequest.remove(id));

  Future<void> _editScene(SceneEditRequest request) async {
    final future = _expect<SceneEditResponse>();
    _publish(request);
    final response = await future;
    if (!response.ok) {
      throw MobilusException(
          'Bramka nie zapisała zmian sceny (kod ${response.status})');
    }
  }

  Future<List<DeviceEvent>> currentState() async {
    final future = _expect<CurrentStateResponse>();
    _publish(const CurrentStateRequest());
    return (await future).events;
  }

  /// [value]: `UP`, `DOWN`, `STOP`, `ON`, `OFF`, `NN%` lub `DOWN:NN$` (lamele).
  void callEvent(int deviceId, String value) {
    _publish(CallEventsRequest([
      DeviceEvent(
        deviceId: deviceId,
        eventNumber: DeviceEvent.commandEventNumber,
        value: value,
      ),
    ]));
  }

  Future<void> dispose() async {
    await _updatesSub?.cancel();
    _updatesSub = null;
    _mqtt?.onDisconnected = null;
    _mqtt?.disconnect();
    _mqtt = null;
    session = null;
  }

  // ------------------------------------------------------------------ private

  Future<void> _subscribe(List<String> topics) async {
    final mqtt = _mqtt!;
    final pending = topics.toSet();
    final done = Completer<void>();
    mqtt.onSubscribed = (topic) {
      pending.remove(topic);
      if (pending.isEmpty && !done.isCompleted) done.complete();
    };
    for (final t in topics) {
      mqtt.subscribe(t, MqttQos.atMostOnce);
    }
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      await dispose();
      throw const MobilusException(
          'Nie udało się zasubskrybować tematów bramki');
    } finally {
      mqtt.onSubscribed = null;
    }
  }

  void _publish(MobilusMessage message) {
    final mqtt = _mqtt;
    if (mqtt == null ||
        mqtt.connectionStatus?.state != MqttConnectionState.connected) {
      throw const MobilusException('Brak połączenia z bramką');
    }
    final frame = MobilusCodec.encode(message, clientId: clientId, keys: _keys);
    mqtt.publishMessage(
        _commandTopic, MqttQos.atMostOnce, Uint8Buffer()..addAll(frame));
  }

  Future<T> _expect<T extends MobilusMessage>() =>
      _incoming.stream.where((m) => m is T).cast<T>().first.timeout(timeout);

  void _onMqttMessages(List<MqttReceivedMessage<MqttMessage>> batch) {
    for (final received in batch) {
      final payload = received.payload;
      if (payload is! MqttPublishMessage) continue;
      final bytes = Uint8List.fromList(payload.payload.message);
      final message = MobilusCodec.decode(bytes, _keys);
      if (message == null) continue;

      _incoming.add(message);
      if (message is CallEventsRequest) {
        message.events.forEach(_events.add);
      }
    }
  }

  static String _randomClientId() {
    final rnd = Random.secure();
    return List.generate(
            6, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }
}
