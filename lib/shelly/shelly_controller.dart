import 'dart:async';

import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import '../screens/shelly_screen.dart';
import '../state/rooms_controller.dart';
import 'shelly_client.dart';
import 'shelly_models.dart';
import 'shelly_store.dart';

/// Urządzenia Shelly w sieci domowej: stan odświeżany co kilka sekund, dopóki aplikacja jest na wierzchu.
class ShellyController extends ChangeNotifier implements DeviceSource {
  ShellyController(
      {ShellyClient? client,
      ShellyStore? store,
      this.pollInterval = const Duration(seconds: 5)})
      : _client = client ?? ShellyClient(),
        _store = store ?? ShellyStore();

  final ShellyClient _client;
  final ShellyStore _store;
  final Duration pollInterval;

  List<ShellyDevice> devices = const [];
  final Map<String, Map<String, ShellyState>> _states = {};
  final Set<String> _unreachable = {};
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  ShellyClient get client => _client;

  @override
  String get id => 'shelly';

  @override
  String get title => 'Shelly';

  @override
  bool get hasDevices => devices.isNotEmpty;

  @override
  String get summary => devices.isEmpty
      ? 'Rolety i światła Shelly w sieci domowej'
      : 'Urządzeń: ${devices.length}${_unreachable.isEmpty ? '' : ' · niedostępne: ${_unreachable.length}'}';

  bool isReachable(String deviceId) => !_unreachable.contains(deviceId);

  Future<void> load() async {
    devices = await _store.load();
    _notify();
    if (_polling) {
      _ensureTimer();
    } else if (hasDevices) {
      unawaited(refresh());
    }
  }

  /// Dodaje urządzenie albo uaktualnia istniejące (ten sam MAC po zmianie adresu IP).
  Future<void> add(ShellyDevice device) async {
    final existing = devices.where((d) => d.id == device.id).firstOrNull;
    final merged =
        existing == null ? device : device.copyWith(name: existing.name);
    devices = [
      for (final d in devices)
        if (d.id != device.id) d,
      merged,
    ];
    await _store.save(devices);
    _notify();
    unawaited(_refreshDevice(merged));
    _ensureTimer();
  }

  Future<void> rename(String deviceId, String name) async {
    devices = [
      for (final d in devices)
        d.id == deviceId ? d.copyWith(name: name.trim()) : d
    ];
    await _store.save(devices);
    _notify();
  }

  Future<void> remove(String deviceId) async {
    devices = devices.where((d) => d.id != deviceId).toList();
    _states.remove(deviceId);
    _unreachable.remove(deviceId);
    await _store.save(devices);
    _notify();
  }

  @override
  void start() {
    _polling = true;
    _ensureTimer();
  }

  @override
  void stop() {
    _polling = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Odpytywanie startuje dopiero, gdy są urządzenia (lista wczytuje się po starcie aplikacji).
  void _ensureTimer() {
    if (!_polling || _timer != null || !hasDevices) return;
    unawaited(refresh());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }

  @override
  Future<void> refresh() =>
      Future.wait([for (final d in devices) _refreshDevice(d)]);

  Future<void> _refreshDevice(ShellyDevice device) async {
    try {
      _states[device.id] = await _client.status(device);
      _unreachable.remove(device.id);
    } on ShellyException {
      _unreachable.add(device.id);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------- sterowanie

  /// Zmienia stan od razu (optymistycznie); przy błędzie wraca do stanu z urządzenia.
  Future<void> _command(
      ShellyDevice device,
      ShellyComponent c,
      ShellyState Function(ShellyState) optimistic,
      Future<void> Function() send) async {
    final before = _states[device.id]?[c.key];
    if (before != null) {
      _states[device.id] = {..._states[device.id]!, c.key: optimistic(before)};
      _notify();
    }
    try {
      await send();
    } on ShellyException {
      _unreachable.add(device.id);
      if (before != null)
        _states[device.id] = {..._states[device.id]!, c.key: before};
      _notify();
      rethrow;
    }
    // Roleta jedzie jeszcze chwilę, więc stan dopiero po krótkiej pauzie.
    unawaited(Future<void>.delayed(
        const Duration(milliseconds: 400), () => _refreshDevice(device)));
  }

  String _label(ShellyDevice d, ShellyComponent c) {
    final same = d.components.where((x) => x.kind == c.kind).length;
    return same > 1 ? '${d.name} · kanał ${c.id + 1}' : d.name;
  }

  @override
  List<SmartLight> get lights => [
        for (final d in devices)
          for (final c in d.components)
            if (c.kind != ShellyKind.cover) _light(d, c),
      ];

  SmartLight _light(ShellyDevice d, ShellyComponent c) {
    final reachable = isReachable(d.id);
    final on = _states[d.id]?[c.key]?.on;
    return SmartLight(
      key: RoomsController.shellyKey(d.id, c.kind.name, c.id),
      name: _label(d, c),
      on: on,
      status: !reachable
          ? 'Niedostępne'
          : on == null
              ? 'stan nieznany'
              : '${on ? 'Włączone' : 'Wyłączone'} · lokalnie',
      icon: reachable ? Icons.wifi : Icons.wifi_off,
      available: reachable,
      set: (value) => _command(d, c, (s) => s.copyWith(on: value),
          () => _client.setOutput(d, c, value)),
    );
  }

  @override
  List<SmartSensor> get sensors => const [];

  @override
  List<SmartCover> get covers => [
        for (final d in devices)
          for (final c in d.components)
            if (c.kind == ShellyKind.cover) _cover(d, c),
      ];

  SmartCover _cover(ShellyDevice d, ShellyComponent c) {
    final reachable = isReachable(d.id);
    final state = _states[d.id]?[c.key];
    final position = state?.position;
    final status = !reachable
        ? 'Niedostępne'
        : state == null
            ? 'stan nieznany'
            : state.moving
                ? 'W ruchu'
                : position == null
                    ? 'Pozycja nieznana (skalibruj w aplikacji Shelly)'
                    : position == 100
                        ? 'Otwarta'
                        : position == 0
                            ? 'Zamknięta'
                            : 'Otwarta w $position%';
    return SmartCover(
      key: RoomsController.shellyKey(d.id, c.kind.name, c.id),
      name: _label(d, c),
      status: status,
      available: reachable,
      position: position,
      moving: state?.moving ?? false,
      // Bez kalibracji urządzenie umie tylko góra/stop/dół.
      supportsPosition: position != null,
      command: (command) => _command(
        d,
        c,
        (s) => switch (command) {
          'UP' => s.copyWith(position: 100),
          'DOWN' => s.copyWith(position: 0),
          _ => command.endsWith('%')
              ? s.copyWith(position: int.tryParse(command.replaceAll('%', '')))
              : s,
        },
        () => _client.coverCommand(d, c, command),
      ),
    );
  }

  @override
  Widget buildSetup(BuildContext context) => ShellyScreen(shelly: this);
}
