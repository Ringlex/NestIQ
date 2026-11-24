import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mobilus/device_info.dart';
import '../mobilus/mobilus_client.dart';
import '../mobilus/proto.dart';
import 'credentials_store.dart';

enum SessionPhase { restoring, loggedOut, connecting, connected }

/// Stan aplikacji: sesja z bramką, lista urządzeń i ich bieżący stan.
class SessionController extends ChangeNotifier {
  SessionController({CredentialsStore? store})
      : _store = store ?? CredentialsStore();

  final CredentialsStore _store;
  MobilusClient? _client;
  StreamSubscription<DeviceEvent>? _eventsSub;
  StreamSubscription<void>? _disconnectSub;
  GatewayCredentials? _credentials;

  SessionPhase phase = SessionPhase.restoring;
  String? error;
  bool refreshing = false;
  bool connectionLost = false;
  List<Device> devices = const [];
  List<GatewayScene> gatewayScenes = const [];
  final Map<int, DeviceStatus> statuses = {};

  String? get gatewaySerial => _client?.session?.serialNumber;
  String? get gatewayHost => _credentials?.host;
  String? get userLogin => _credentials?.login;
  bool get isAdmin => _client?.session?.admin ?? false;
  int? get userId => _client?.session?.userId;

  Future<(String?, String?)> lastHostAndLogin() => _store.lastHostAndLogin();

  /// Przy starcie próbuje zalogować się zapisanymi danymi.
  Future<void> restore() async {
    final saved = await _store.load();
    if (saved == null) {
      _setPhase(SessionPhase.loggedOut);
      return;
    }
    await login(saved, remember: true);
  }

  Future<bool> login(GatewayCredentials credentials,
      {required bool remember}) async {
    error = null;
    _setPhase(SessionPhase.connecting);
    await _closeClient();

    final client = MobilusClient(
      host: credentials.host,
      login: credentials.login,
      password: credentials.password,
    );
    try {
      await client.connect();
      final list = await client.devicesList();
      _client = client;
      _credentials = credentials;
      devices = list
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      connectionLost = false;
      _eventsSub = client.events.listen(_onEvent);
      _disconnectSub = client.disconnected.listen((_) {
        connectionLost = true;
        notifyListeners();
      });
      if (remember) {
        await _store.save(credentials);
      }
      _setPhase(SessionPhase.connected);
      unawaited(_loadState());
      unawaited(_loadScenes());
      return true;
    } catch (e) {
      await client.dispose();
      error = e.toString();
      _setPhase(SessionPhase.loggedOut);
      return false;
    }
  }

  Future<void> refresh() async {
    final creds = _credentials;
    if (creds == null) return;
    if (connectionLost || !(_client?.isConnected ?? false)) {
      await _reconnect(creds);
      return;
    }
    refreshing = true;
    notifyListeners();
    try {
      final list = await _client!.devicesList();
      devices = list
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      await _loadState();
      await _loadScenes();
    } catch (e) {
      error = e.toString();
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  /// Wysyła komendę do urządzenia, przy zerwanym połączeniu łączy się ponownie.
  Future<void> send(Device device, String value) => sendAll({device.id: value});

  /// Wysyła komendy do wielu urządzeń naraz (np. scena): identyfikator → wartość.
  Future<void> sendAll(Map<int, String> commands) async {
    final creds = _credentials;
    if (creds == null || commands.isEmpty) return;
    if (connectionLost || !(_client?.isConnected ?? false)) {
      await _reconnect(creds);
    }
    try {
      for (final MapEntry(key: id, value: value) in commands.entries) {
        _client?.callEvent(id, value);
      }
      // Bramka raportuje stan z opóźnieniem, więc odpytujemy go po chwili
      // i ponownie po typowym czasie przejazdu rolety.
      for (final delay in const [Duration(seconds: 3), Duration(seconds: 25)]) {
        Timer(delay, () {
          if (_client?.isConnected ?? false) unawaited(_loadState());
        });
      }
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  /// Zapisuje scenę w bramce i pobiera listę od nowa. Błąd trafia do wywołującego.
  Future<void> saveScene(GatewayScene scene) =>
      _editScenes((c) => c.saveScene(scene));

  Future<void> removeScene(GatewayScene scene) =>
      _editScenes((c) => c.removeScene(scene.id));

  Future<void> _editScenes(
      Future<void> Function(MobilusClient client) edit) async {
    final creds = _credentials;
    if (creds == null) return;
    if (connectionLost || !(_client?.isConnected ?? false)) {
      await _reconnect(creds);
    }
    final client = _client;
    if (client == null)
      throw const MobilusException('Brak połączenia z bramką');
    await edit(client);
    await _loadScenes();
  }

  Future<void> logout() async {
    await _closeClient();
    await _store.clear();
    _credentials = null;
    devices = const [];
    gatewayScenes = const [];
    statuses.clear();
    _setPhase(SessionPhase.loggedOut);
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ private

  Future<void> _reconnect(GatewayCredentials creds) async {
    refreshing = true;
    notifyListeners();
    await _closeClient();
    final client = MobilusClient(
        host: creds.host, login: creds.login, password: creds.password);
    try {
      await client.connect();
      _client = client;
      _eventsSub = client.events.listen(_onEvent);
      _disconnectSub = client.disconnected.listen((_) {
        connectionLost = true;
        notifyListeners();
      });
      connectionLost = false;
      await _loadState();
      await _loadScenes();
    } catch (e) {
      await client.dispose();
      error = e.toString();
      connectionLost = true;
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  Future<void> _loadState() async {
    try {
      final events = await _client!.currentState();
      for (final e in events) {
        statuses[e.deviceId] = DeviceStatus(e);
      }
      notifyListeners();
    } catch (_) {
      // Stan jest opcjonalny – lista urządzeń działa bez niego.
    }
  }

  Future<void> _loadScenes() async {
    try {
      gatewayScenes = await _client!.scenesList();
      notifyListeners();
    } catch (_) {
      // Sceny są opcjonalne – starsze bramki mogą ich nie obsługiwać.
    }
  }

  void _onEvent(DeviceEvent event) {
    // Bramka unieważniła sesję – następna komenda lub odświeżenie zaloguje ponownie.
    if (event.eventNumber == DeviceEvent.sessionEventNumber) {
      connectionLost = true;
      notifyListeners();
      final creds = _credentials;
      if (creds != null && !refreshing) unawaited(_reconnect(creds));
      return;
    }
    // Ktoś (np. aplikacja Mobilus) zmienił sceny – pobieramy je od nowa.
    if (event.eventNumber == DeviceEvent.configEventNumber) {
      unawaited(_loadScenes());
      return;
    }
    // Stanem rolet są tylko zdarzenia 7 i 8; komendy (6) i inne pomijamy.
    if (event.eventNumber != DeviceEvent.stateEventNumber &&
        event.eventNumber != DeviceEvent.movingEventNumber) {
      return;
    }
    statuses[event.deviceId] = DeviceStatus(event);
    notifyListeners();
  }

  Future<void> _closeClient() async {
    await _eventsSub?.cancel();
    await _disconnectSub?.cancel();
    _eventsSub = null;
    _disconnectSub = null;
    await _client?.dispose();
    _client = null;
  }

  void _setPhase(SessionPhase p) {
    phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _closeClient();
    super.dispose();
  }
}
