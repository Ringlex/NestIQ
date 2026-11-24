import 'dart:async';

import 'package:flutter/foundation.dart';

import '../devices/smart_device.dart';
import 'tuya_cloud_client.dart';
import 'tuya_settings.dart';
import 'tuya_discovery.dart';
import 'tuya_lan_client.dart';
import 'tuya_models.dart';
import 'tuya_store.dart';

typedef TuyaLanFactory = TuyaLanLink Function(
    TuyaDevice device, String version);
typedef TuyaCloudFactory = TuyaCloudApi Function(
    TuyaCloudCredentials credentials);
typedef TuyaDiscoverer = Future<List<TuyaDiscovered>> Function();

class TuyaControlException implements Exception, DeviceControlException {
  const TuyaControlException(this.message);
  @override
  final String message;

  @override
  String toString() => message;
}

class TuyaImportResult {
  const TuyaImportResult({required this.added, required this.total});
  final int added;
  final int total;
}

/// Pojedyncze światło: jeden przycisk włącznika Tuya.
typedef TuyaLight = ({TuyaDevice device, TuyaChannel channel});

/// Włączniki Tuya: dane, połączenia i sterowanie.
///
/// W trybie automatycznym urządzenie obsługujemy przez sieć lokalną (szybko,
/// bez chmury), a gdy połączenie lokalne nie jest możliwe – przez chmurę Tuya.
/// Połączenia lokalne są trwałe i same się odtwarzają z narastającą przerwą.
class TuyaController extends ChangeNotifier {
  /// Dla rozszerzenia poniżej: `notifyListeners` wolno wołać tylko z klasy.
  void _notify() => notifyListeners();

  TuyaController({
    TuyaStore? store,
    TuyaLanFactory? lanFactory,
    TuyaCloudFactory? cloudFactory,
    TuyaDiscoverer? discoverer,
    this.cloudPollInterval = const Duration(seconds: 20),
    this.sensorPollInterval = const Duration(minutes: 5),
    this.retryBase = const Duration(seconds: 5),
  })  : _store = store ?? SecureTuyaStore(),
        _lanFactory = lanFactory ?? _defaultLan,
        _cloudFactory =
            cloudFactory ?? ((c) => TuyaCloudClient(credentials: c)),
        _discoverer = discoverer ?? TuyaDiscovery.scan;

  final TuyaStore _store;
  final TuyaLanFactory _lanFactory;
  final TuyaCloudFactory _cloudFactory;
  final TuyaDiscoverer _discoverer;
  final Duration cloudPollInterval;

  /// Czujniki odpytujemy rzadko: baterie i limity zapytań do chmury Tuya.
  final Duration sensorPollInterval;
  final Duration retryBase;

  static TuyaLanLink _defaultLan(TuyaDevice device, String version) =>
      TuyaLanClient(
        deviceId: device.id,
        localKey: device.localKey,
        version: version,
        host: device.ip!,
        connectTimeout: const Duration(seconds: 3),
        requestTimeout: const Duration(seconds: 3),
      );

  static const _versions = ['3.3', '3.4', '3.5'];

  List<TuyaDevice> devices = const [];
  TuyaCloudCredentials? credentials;
  TuyaMode mode = TuyaMode.auto;
  bool loaded = false;

  final Map<String, TuyaRoute> _routes = {};
  final Map<String, bool> _states = {};
  final Map<String, _Session> _sessions = {};
  final Map<String, Timer> _retries = {};
  final Map<String, int> _failures = {};
  final Map<String, String> _lanErrors = {};
  final Map<String, String> _cloudErrors = {};
  final Set<String> _connecting = {};
  TuyaCloudApi? _cloud;
  Timer? _poll;
  Timer? _sensorPoll;
  final Map<String, Map<String, Object?>> _readings = {};
  final Map<String, DateTime> _readingAt = {};
  Timer? _followUp;
  bool _active = false;

  // ---------------------------------------------------------------- odczyt

  bool get hasDevices => devices.isNotEmpty;

  bool get cloudAvailable => mode != TuyaMode.local && credentials != null;

  TuyaRoute routeOf(String deviceId) => _routes[deviceId] ?? TuyaRoute.offline;

  /// Dlaczego urządzenie jest niedostępne: ostatnie błędy sieci lokalnej i chmury.
  String? problemOf(String deviceId) {
    final parts = [
      if (_lanErrors[deviceId] != null) 'sieć lokalna: ${_lanErrors[deviceId]}',
      if (_cloudErrors[deviceId] != null) 'chmura: ${_cloudErrors[deviceId]}',
    ];
    return parts.isEmpty ? null : parts.join('\n');
  }

  /// `null`, gdy stan jeszcze nieznany.
  bool? isOn(String deviceId, int dpId) => _states['$deviceId:$dpId'];

  /// Czujniki (temperatura i wilgotność); odczyt tylko przez chmurę, bo czujniki na baterię
  /// śpią i nie przyjmują połączeń w sieci lokalnej.
  List<TuyaDevice> get sensorDevices => [
        for (final d in devices)
          if (d.isSensor) d
      ];

  /// Ostatni odczyt czujnika albo `null`, gdy jeszcze go nie było.
  TuyaReading? readingOf(String deviceId) {
    final raw = _readings[deviceId];
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    if (raw == null || device == null) return null;
    double? valueOf(TuyaMetricKind kind) {
      final metric = device.metrics.where((m) => m.kind == kind).firstOrNull;
      final v = metric == null ? null : raw[metric.code];
      return v is num ? metric!.value(v) : null;
    }

    return TuyaReading(
      temperature: valueOf(TuyaMetricKind.temperature),
      humidity: valueOf(TuyaMetricKind.humidity),
      battery: valueOf(TuyaMetricKind.battery)?.round(),
      updatedAt: _readingAt[deviceId],
    );
  }

  /// Ustawienia czujnika z bieżącymi wartościami z ostatniego odczytu.
  List<SensorSetting> settingsOf(TuyaDevice device) => [
        for (final s in device.settings)
          describeTuyaSetting(
            s,
            current: _readings[device.id]?[s.code],
            set: (value) => changeSetting(device, s, value),
          ),
      ];

  /// Zapisuje ustawienie czujnika w chmurze. Czujnik na baterii przyjmie je dopiero
  /// po przebudzeniu, ale chmura potwierdza zapis od razu.
  Future<void> changeSetting(
      TuyaDevice device, TuyaSetting setting, Object value) async {
    if (!cloudAvailable) {
      throw const TuyaControlException(
          'Ustawienia czujnika zmienisz tylko przez chmurę. Dodaj jej dane w ustawieniach Tuya.');
    }
    final Object raw =
        setting.isChoice ? '$value' : setting.raw(value as double);
    try {
      await _cloudClient().setValue(device.id, setting.code, raw);
    } on TuyaCloudException catch (e) {
      throw TuyaControlException('Nie udało się zapisać: ${e.message}');
    }
    (_readings[device.id] ??= {})[setting.code] = raw;
    _notify();
  }

  List<TuyaLight> get lights => [
        for (final d in devices)
          for (final c in d.channels) (device: d, channel: c),
      ];

  // ---------------------------------------------------------------- cykl życia

  Future<void> load() async {
    final saved = await _store.load();
    devices = saved.devices;
    credentials = saved.credentials;
    mode = saved.mode;
    loaded = true;
    notifyListeners();
  }

  /// Uruchamia połączenia lokalne i odpytywanie chmury; wołać, gdy aplikacja jest na wierzchu.
  void start() {
    if (_active) return;
    _active = true;
    for (final d in devices) {
      unawaited(_connect(d));
    }
    _updatePolling();
    _updateSensorPolling();
  }

  /// Zamyka połączenia i timery (aplikacja w tle).
  void stop() {
    _active = false;
    _poll?.cancel();
    _poll = null;
    _sensorPoll?.cancel();
    _sensorPoll = null;
    _followUp?.cancel();
    for (final t in _retries.values) {
      t.cancel();
    }
    _retries.clear();
    for (final s in _sessions.values) {
      s.dispose();
    }
    _sessions.clear();
    _connecting.clear();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Przeciągnięcie listy w dół: ponawia połączenia lokalne i odświeża stan z chmury.
  Future<void> refresh() async {
    if (!_active) return;
    for (final d in devices) {
      if (d.channels.isNotEmpty && !_sessions.containsKey(d.id)) {
        _failures.remove(d.id);
        unawaited(_connect(d));
      }
    }
    await _pollCloud();
    await _pollSensors();
  }

  // ---------------------------------------------------------------- sterowanie

  Future<void> setChannel(
      TuyaDevice device, TuyaChannel channel, bool on) async {
    final key = '${device.id}:${channel.dpId}';
    final previous = _states[key];
    _states[key] = on;
    notifyListeners();

    try {
      final session = _sessions[device.id];
      if (session != null &&
          session.link.isConnected &&
          mode != TuyaMode.cloud) {
        try {
          await session.link.setDps({'${channel.dpId}': on});
          return;
        } on Object {
          // Połączenie lokalne zawiodło w trakcie polecenia: spróbujemy chmurą.
          if (!cloudAvailable) rethrow;
        }
      }
      if (cloudAvailable) {
        await _cloudClient().setSwitch(device.id, channel.code, on);
        _routes[device.id] = TuyaRoute.cloud;
        // Chmura potwierdza polecenie z opóźnieniem, więc stan odczytujemy chwilę później.
        _followUp?.cancel();
        _followUp = Timer(const Duration(milliseconds: 1500),
            () => unawaited(_pollCloud(only: device)));
        return;
      }
      throw TuyaControlException(mode == TuyaMode.cloud
          ? 'Dodaj dane chmury Tuya w ustawieniach, żeby sterować przez chmurę.'
          : '${device.name} nie jest dostępny w sieci lokalnej.');
    } on Object catch (e) {
      if (previous == null) {
        _states.remove(key);
      } else {
        _states[key] = previous;
      }
      notifyListeners();
      throw e is TuyaControlException
          ? e
          : TuyaControlException('${device.name}: $e');
    } finally {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- konfiguracja

  Future<TuyaImportResult> importFromCloud(TuyaCloudCredentials next) async {
    final imported = await _cloudFactory(next).importDevices();
    final existing = {for (final d in devices) d.id: d};
    var added = 0;
    final merged = <TuyaDevice>[
      for (final d in imported)
        if (existing[d.id] case final old?)
          // Zachowujemy to, czego chmura nie zna: adres, wykrytą wersję i własną nazwę.
          d.copyWith(version: old.version, ip: old.ip, name: old.name)
        else
          d,
    ];
    for (final d in imported) {
      if (!existing.containsKey(d.id)) added++;
    }
    // Urządzenia dodane ręcznie albo już nieobecne w chmurze zostają, żeby nie gubić ustawień.
    for (final old in devices) {
      if (!imported.any((d) => d.id == old.id)) merged.add(old);
    }

    credentials = next;
    _cloud = null;
    devices = merged;
    await _store.saveCredentials(next);
    await _store.saveDevices(merged);
    _restartSessions();
    _updateSensorPolling();
    notifyListeners();
    return TuyaImportResult(added: added, total: imported.length);
  }

  Future<void> clearCredentials() async {
    credentials = null;
    _cloud = null;
    await _store.saveCredentials(null);
    _updatePolling();
    _updateSensorPolling();
    _refreshAllRoutes();
    notifyListeners();
  }

  /// Szuka urządzeń w sieci i uzupełnia ich adresy. Zwraca liczbę dopasowanych.
  Future<int> discover() async {
    final found = {for (final f in await _discoverer()) f.id: f};
    var matched = 0;
    final updated = <TuyaDevice>[];
    for (final d in devices) {
      final f = found[d.id];
      if (f == null) {
        updated.add(d);
        continue;
      }
      matched++;
      final version =
          const {'3.3', '3.4', '3.5'}.contains(f.version) ? f.version : null;
      updated.add(d.copyWith(ip: f.ip, version: version));
    }
    devices = updated;
    await _store.saveDevices(updated);
    _restartSessions();
    notifyListeners();
    return matched;
  }

  Future<void> updateDevice(TuyaDevice device) async {
    devices = [for (final d in devices) d.id == device.id ? device : d];
    await _store.saveDevices(devices);
    await _drop(device.id);
    unawaited(_connect(device));
    notifyListeners();
  }

  Future<void> removeDevice(String id) async {
    devices = devices.where((d) => d.id != id).toList();
    await _store.saveDevices(devices);
    await _drop(id);
    _routes.remove(id);
    _states.removeWhere((k, _) => k.startsWith('$id:'));
    _readings.remove(id);
    _readingAt.remove(id);
    _updateSensorPolling();
    notifyListeners();
  }

  Future<void> setMode(TuyaMode next) async {
    mode = next;
    await _store.saveMode(next);
    _restartSessions();
    notifyListeners();
  }

  // ---------------------------------------------------------------- połączenia

  TuyaCloudApi _cloudClient() => _cloud ??= _cloudFactory(credentials!);

  Future<void> _drop(String id) async {
    _retries.remove(id)?.cancel();
    _failures.remove(id);
    _lanErrors.remove(id);
    final session = _sessions.remove(id);
    session?.dispose();
    await session?.link.close();
  }

  void _restartSessions() {
    final wasActive = _active;
    for (final id in _sessions.keys.toList()) {
      unawaited(_drop(id));
    }
    for (final t in _retries.values) {
      t.cancel();
    }
    _retries.clear();
    if (wasActive) {
      for (final d in devices) {
        unawaited(_connect(d));
      }
    }
    _updatePolling();
    _refreshAllRoutes();
  }

  Future<void> _connect(TuyaDevice device) async {
    // Same czujniki nie mają przycisków do sterowania, więc nie łączymy się z nimi lokalnie.
    if (device.channels.isEmpty) return;
    if (!_active || mode == TuyaMode.cloud || device.ip == null) {
      if (mode != TuyaMode.cloud && device.ip == null) {
        _lanErrors[device.id] =
            'brak adresu IP (użyj „Skanuj sieć” albo wpisz go ręcznie)';
      }
      _refreshRoute(device.id);
      return;
    }
    if (_sessions.containsKey(device.id) || !_connecting.add(device.id)) return;

    _routes.putIfAbsent(device.id, () => TuyaRoute.connecting);
    if (_routes[device.id] == TuyaRoute.offline)
      _routes[device.id] = TuyaRoute.connecting;
    notifyListeners();

    final order = [
      device.version,
      ..._versions.where((v) => v != device.version)
    ];
    try {
      for (final version in order) {
        final link = _lanFactory(device, version);
        try {
          await link.connect();
          final status = await link.queryStatus();
          if (!_active || !devices.any((d) => d.id == device.id)) {
            await link.close();
            return;
          }
          _adopt(device, version, link, status);
          return;
        } on Object catch (e) {
          _lanErrors[device.id] = '$e';
          await link.close();
        }
      }
      _scheduleRetry(device.id);
      _refreshRoute(device.id);
    } finally {
      _connecting.remove(device.id);
      notifyListeners();
    }
  }

  void _adopt(TuyaDevice device, String version, TuyaLanLink link,
      Map<String, Object?> status) {
    _applyDps(device.id, status);
    final sub = link.updates.listen((dps) {
      _applyDps(device.id, dps);
      notifyListeners();
    });
    _sessions[device.id] = _Session(link, sub);
    _failures.remove(device.id);
    _lanErrors.remove(device.id);
    _routes[device.id] = TuyaRoute.local;

    // Wykryta wersja protokołu zostaje zapamiętana, żeby kolejne połączenia były szybkie.
    if (version != device.version) {
      final fixed = device.copyWith(version: version);
      devices = [for (final d in devices) d.id == device.id ? fixed : d];
      unawaited(_store.saveDevices(devices));
    }

    unawaited(link.closed.then((_) => _onClosed(device.id, link)));
    _updatePolling();
  }

  void _onClosed(String id, TuyaLanLink link) {
    final session = _sessions[id];
    if (session == null || !identical(session.link, link)) return;
    _sessions.remove(id)?.dispose();
    if (!_active) return;
    _scheduleRetry(id);
    _refreshRoute(id);
    _updatePolling();
    notifyListeners();
  }

  void _scheduleRetry(String id) {
    if (!_active) return;
    final failures = (_failures[id] ?? 0) + 1;
    _failures[id] = failures;
    // 5 s, 10 s, 20 s… do minuty.
    final delay = retryBase * (1 << (failures - 1).clamp(0, 4));
    _retries[id]?.cancel();
    _retries[id] = Timer(
        delay > const Duration(minutes: 1) ? const Duration(minutes: 1) : delay,
        () {
      final device = devices.where((d) => d.id == id).firstOrNull;
      if (device != null) unawaited(_connect(device));
    });
  }

  void _refreshRoute(String id) {
    if (_sessions.containsKey(id)) {
      _routes[id] = TuyaRoute.local;
    } else if (cloudAvailable) {
      _routes[id] = TuyaRoute.cloud;
    } else if (!_connecting.contains(id)) {
      _routes[id] = TuyaRoute.offline;
    }
  }

  void _refreshAllRoutes() {
    for (final d in devices) {
      _refreshRoute(d.id);
    }
  }

  void _applyDps(String deviceId, Map<String, Object?> dps) {
    for (final entry in dps.entries) {
      final value = entry.value;
      if (value is bool) _states['$deviceId:${entry.key}'] = value;
    }
  }

  // ---------------------------------------------------------------- chmura

  void _updatePolling() {
    final needed = _active &&
        cloudAvailable &&
        devices
            .any((d) => d.channels.isNotEmpty && !_sessions.containsKey(d.id));
    if (!needed) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    if (_poll != null) return;
    unawaited(_pollCloud());
    _poll = Timer.periodic(cloudPollInterval, (_) => unawaited(_pollCloud()));
  }

  /// Stan urządzeń bez połączenia lokalnego (albo [only]) z chmury.
  Future<void> _pollCloud({TuyaDevice? only}) async {
    if (!cloudAvailable) return;
    final targets = only != null
        ? [only]
        : devices
            .where((d) => d.channels.isNotEmpty && !_sessions.containsKey(d.id))
            .toList();
    var changed = false;
    for (final d in targets) {
      try {
        final states = await _cloudClient().switchStates(d.id);
        for (final c in d.channels) {
          final on = states[c.code];
          if (on != null) _states['${d.id}:${c.dpId}'] = on;
        }
        _routes[d.id] = TuyaRoute.cloud;
        _cloudErrors.remove(d.id);
      } on Object catch (e) {
        _cloudErrors[d.id] = '$e';
        if (!_sessions.containsKey(d.id)) _routes[d.id] = TuyaRoute.offline;
      }
      changed = true;
    }
    if (changed) notifyListeners();
  }
}

extension on TuyaController {
  void _updateSensorPolling() {
    final needed = _active && cloudAvailable && sensorDevices.isNotEmpty;
    if (!needed) {
      _sensorPoll?.cancel();
      _sensorPoll = null;
      return;
    }
    if (_sensorPoll != null) return;
    unawaited(_pollSensors());
    _sensorPoll =
        Timer.periodic(sensorPollInterval, (_) => unawaited(_pollSensors()));
  }

  /// Odczyty wszystkich czujników z chmury; błąd jednego nie przerywa pozostałych.
  Future<void> _pollSensors() async {
    if (!cloudAvailable) return;
    var changed = false;
    for (final d in sensorDevices) {
      try {
        _readings[d.id] = await _cloudClient().deviceStatus(d.id);
        _readingAt[d.id] = DateTime.now();
        _cloudErrors.remove(d.id);
      } on Object catch (e) {
        _cloudErrors[d.id] = '$e';
      }
      changed = true;
    }
    if (changed) _notify();
  }
}

/// Odczyt czujnika Tuya po przeliczeniu skali.
class TuyaReading {
  const TuyaReading(
      {this.temperature, this.humidity, this.battery, this.updatedAt});

  final double? temperature;
  final double? humidity;
  final int? battery;
  final DateTime? updatedAt;
}

class _Session {
  _Session(this.link, this.subscription);

  final TuyaLanLink link;
  final StreamSubscription<Map<String, Object?>> subscription;

  void dispose() => unawaited(subscription.cancel());
}
