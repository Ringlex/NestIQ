import 'dart:async';

import 'package:flutter/material.dart';

import '../devices/smart_device.dart';
import '../screens/hue_screen.dart';
import '../state/rooms_controller.dart';
import 'hue_client.dart';
import 'hue_models.dart';
import 'hue_store.dart';

/// Lampki Philips Hue przez lokalny mostek; stan odświeżany jednym zapytaniem co kilka sekund.
class HueController extends ChangeNotifier implements DeviceSource {
  HueController(
      {HueClient? client,
      HueStore? store,
      this.pollInterval = const Duration(seconds: 5)})
      : _client = client ?? HueClient(),
        _store = store ?? SecureHueStore();

  final HueClient _client;
  final HueStore _store;
  final Duration pollInterval;

  HueBridge? bridge;
  List<HueLight> _lights = const [];
  bool reachable = true;
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  HueClient get client => _client;

  @override
  String get id => 'hue';

  @override
  String get title => 'Philips Hue';

  @override
  bool get hasDevices => bridge != null;

  @override
  String get summary => bridge == null
      ? 'Niepodłączony'
      : 'Mostek ${bridge!.host} · lamp: ${_lights.length}${reachable ? '' : ' · niedostępny'}';

  Future<void> load() async {
    bridge = await _store.load();
    _notify();
    if (_polling) {
      _ensureTimer();
    } else if (bridge != null) {
      unawaited(refresh());
    }
  }

  /// Zapisuje sparowany mostek (ten sam identyfikator = zmiana adresu IP).
  Future<void> connect(HueBridge value) async {
    bridge = value;
    await _store.save(value);
    _lights = const [];
    reachable = true;
    _notify();
    unawaited(refresh());
    _ensureTimer();
  }

  Future<void> disconnect() async {
    stopTimer();
    bridge = null;
    _lights = const [];
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
    stopTimer();
  }

  void stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _ensureTimer() {
    if (!_polling || _timer != null || bridge == null) return;
    unawaited(refresh());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }

  @override
  Future<void> refresh() async {
    final b = bridge;
    if (b == null) return;
    try {
      _lights = await _client.lights(b);
      reachable = true;
    } on HueException {
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

  Future<void> _command(HueLight before, HueLight Function(HueLight) optimistic,
      Future<void> Function(HueBridge) send) async {
    final b = bridge;
    if (b == null) return;
    _replace(optimistic(before));
    try {
      await send(b);
    } on HueException {
      _replace(before);
      reachable = false;
      _notify();
      rethrow;
    }
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), refresh));
  }

  void _replace(HueLight light) {
    _lights = [for (final l in _lights) l.id == light.id ? light : l];
    _notify();
  }

  @override
  List<SmartLight> get lights {
    final b = bridge;
    if (b == null) return const [];
    return [
      for (final l in _lights)
        SmartLight(
          key: RoomsController.hueKey(b.id, l.id),
          name: l.name,
          on: l.on,
          status: !reachable
              ? 'Mostek niedostępny'
              : !l.reachable
                  ? 'Lampa niedostępna'
                  : l.on
                      ? 'Włączone${l.brightness == null ? '' : ' · ${l.brightness}%'} · Hue'
                      : 'Wyłączone · Hue',
          icon: Icons.hub_outlined,
          available: reachable && l.reachable,
          set: (value) => _command(l, (x) => x.copyWith(on: value),
              (br) => _client.setOn(br, l.id, value)),
          brightness: l.brightness,
          setBrightness: l.brightness == null
              ? null
              : (percent) => _command(
                    l,
                    (x) => x.copyWith(on: true, brightness: percent),
                    (br) => _client.setBrightness(br, l.id, percent),
                  ),
        ),
    ];
  }

  @override
  List<SmartSensor> get sensors => const [];

  @override
  List<SmartCover> get covers => const [];

  @override
  Widget buildSetup(BuildContext context) => HueScreen(hue: this);
}
