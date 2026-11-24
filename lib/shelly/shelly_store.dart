import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'shelly_models.dart';

/// Zapisane urządzenia Shelly. Adresy w sieci domowej nie są tajne, więc zwykłe ustawienia.
class ShellyStore {
  static const _key = 'shelly_v1';

  Future<List<ShellyDevice>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const [];
      return [
        for (final d in jsonDecode(raw) as List)
          ShellyDevice.fromJson((d as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<ShellyDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode([for (final d in devices) d.toJson()]));
  }
}
