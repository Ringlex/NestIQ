import 'dart:async';

import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import '../screens/somfy_screen.dart';
import '../state/rooms_controller.dart';
import 'somfy_client.dart';
import 'somfy_models.dart';
import 'somfy_store.dart';

/// Rolety Somfy przez lokalne API skrzynki TaHoma; stan z jednego zapytania co kilka sekund.
class SomfyController extends ChangeNotifier implements DeviceSource {
  SomfyController({
    SomfyClient? client,
    SomfyStore? store,
    this.pollInterval = const Duration(seconds: 8),
    this.settleDelay = const Duration(milliseconds: 1500),
  })  : _client = client ?? SomfyClient(),
        _store = store ?? SecureSomfyStore();

  final SomfyClient _client;
  final SomfyStore _store;

  /// Skrzynka prosi o rzadkie odpytywanie, bo częste zapytania spowalniają sterowanie.
  final Duration pollInterval;

  /// Po poleceniu roleta jedzie jeszcze chwilę; stan odczytujemy po tej pauzie.
  final Duration settleDelay;

  SomfyGateway? gateway;
  List<SomfyCover> _covers = const [];
  bool reachable = true;
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  SomfyClient get client => _client;

  @override
  String get id => 'somfy';

  @override
  String get title => 'Somfy TaHoma';

  @override
  bool get hasDevices => gateway != null;

  @override
  String get summary => gateway == null
      ? 'Niepodłączona'
      : 'Skrzynka ${gateway!.id} · urządzeń: ${_covers.length}${reachable ? '' : ' · niedostępna'}';

  Future<void> load() async {
    gateway = await _store.load();
    _notify();
    if (_polling) {
      _ensureTimer();
    } else if (gateway != null) {
      unawaited(refresh());
    }
  }

  Future<void> connect(SomfyGateway value) async {
    gateway = value;
    await _store.save(value);
    _covers = const [];
    reachable = true;
    _notify();
    unawaited(refresh());
    _ensureTimer();
  }

  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    gateway = null;
    _covers = const [];
    reachable = true;
    await _store.clear();
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

  void _ensureTimer() {
    if (!_polling || _timer != null || gateway == null) return;
    unawaited(refresh());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }

  @override
  Future<void> refresh() async {
    final gw = gateway;
    if (gw == null) return;
    try {
      _covers = await _client.covers(gw);
      reachable = true;
    } on SomfyException {
      reachable = false;
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

  Future<void> _command(SomfyCover cover, String command) async {
    final gw = gateway;
    if (gw == null) return;
    final before = _covers;
    final optimistic = switch (command) {
      'UP' => 0,
      'DOWN' => 100,
      _ => command.endsWith('%')
          ? 100 - (int.tryParse(command.replaceAll('%', '')) ?? 100)
          : null,
    };
    if (optimistic != null) {
      _covers = [
        for (final c in _covers)
          c.url == cover.url ? c.withClosure(optimistic) : c
      ];
      _notify();
    }
    try {
      await _client.command(gw, cover, command);
    } on SomfyException catch (e) {
      _covers = before;
      if (e.code != 'unsupported') reachable = false;
      _notify();
      rethrow;
    }
    unawaited(Future<void>.delayed(settleDelay, refresh));
  }

  @override
  List<SmartSensor> get sensors => const [];

  @override
  List<SmartLight> get lights => const [];

  @override
  List<SmartCover> get covers {
    final gw = gateway;
    if (gw == null) return const [];
    return [
      for (final c in _covers)
        SmartCover(
          key: RoomsController.somfyKey(gw.id, c.url),
          name: c.name,
          available: reachable && c.available,
          position: c.position,
          supportsPosition: c.canSetPosition && c.position != null,
          status: !reachable
              ? 'Skrzynka niedostępna'
              : !c.available
                  ? 'Niedostępna'
                  : c.position == null
                      ? 'stan nieznany'
                      : c.position == 100
                          ? 'Otwarta'
                          : c.position == 0
                              ? 'Zamknięta'
                              : 'Otwarta w ${c.position}%',
          command: (command) => _command(c, command),
        ),
    ];
  }

  @override
  Widget buildSetup(BuildContext context) => SomfyScreen(somfy: this);
}
