import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'hue_models.dart';

abstract class HueStore {
  Future<HueBridge?> load();
  Future<void> save(HueBridge bridge);
  Future<void> clear();
}

/// Klucz aplikacji Hue daje pełną kontrolę nad mostkiem, więc ląduje w Keychain / Keystore.
class SecureHueStore implements HueStore {
  SecureHueStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'hue_bridge';

  @override
  Future<HueBridge?> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      return HueBridge.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(HueBridge bridge) =>
      _storage.write(key: _key, value: jsonEncode(bridge.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
