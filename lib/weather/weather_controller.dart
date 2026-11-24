import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'weather_client.dart';
import 'weather_models.dart';

/// Pogoda dla jednej miejscowości: zapamiętana, odświeżana rzadko, widoczna też bez internetu.
class WeatherController extends ChangeNotifier {
  WeatherController({
    WeatherClient? client,
    this.refreshInterval = const Duration(minutes: 30),
    this.minAge = const Duration(minutes: 10),
  }) : _client = client ?? WeatherClient();

  static const _key = 'weather_v1';

  final WeatherClient _client;

  /// Jak często odświeżamy, gdy aplikacja jest na wierzchu.
  final Duration refreshInterval;

  /// Prognoza młodsza niż to nie jest pobierana ponownie (chyba że wymuszone).
  final Duration minAge;

  WeatherClient get client => _client;

  WeatherPlace? place;
  WeatherForecast? forecast;
  bool loading = false;

  /// Komunikat ostatniego nieudanego odświeżenia; `null`, gdy wszystko dobrze.
  String? error;

  Timer? _timer;
  bool _active = false;
  bool _disposed = false;

  bool get hasPlace => place != null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      place =
          WeatherPlace.fromJson((json['place'] as Map).cast<String, dynamic>());
      if (json['forecast'] is Map) {
        forecast = WeatherForecast.fromJson(
            (json['forecast'] as Map).cast<String, dynamic>());
      }
      _notify();
      if (_active) unawaited(refresh());
    } catch (_) {
      // Uszkodzony zapis traktujemy jak brak miejscowości.
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    if (place == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(
          _key,
          jsonEncode(
              {'place': place!.toJson(), 'forecast': forecast?.toJson()}));
    }
  }

  Future<void> setPlace(WeatherPlace value) async {
    place = value;
    forecast = null;
    error = null;
    _notify();
    await _save();
    await refresh(force: true);
    if (_active && _timer == null) {
      _timer = Timer.periodic(
          refreshInterval, (_) => unawaited(refresh(force: true)));
    }
  }

  Future<void> clear() async {
    place = null;
    forecast = null;
    error = null;
    _timer?.cancel();
    _timer = null;
    _notify();
    await _save();
  }

  /// Odświeża prognozę; przy błędzie zostaje poprzednia razem z komunikatem.
  Future<void> refresh({bool force = false}) async {
    final p = place;
    if (p == null || loading) return;
    final last = forecast;
    if (!force &&
        last != null &&
        DateTime.now().difference(last.fetchedAt) < minAge) return;
    loading = true;
    _notify();
    try {
      forecast = await _client.forecast(p);
      error = null;
      await _save();
    } on WeatherException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      _notify();
    }
  }

  void start() {
    _active = true;
    _timer?.cancel();
    if (!hasPlace) return;
    unawaited(refresh());
    _timer =
        Timer.periodic(refreshInterval, (_) => unawaited(refresh(force: true)));
  }

  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
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
}
