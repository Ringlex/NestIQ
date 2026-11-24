import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'somfy_models.dart';

abstract class SomfyStore {
  Future<SomfyGateway?> load();
  Future<void> save(SomfyGateway gateway);
  Future<void> clear();
}

/// Token trybu dewelopera daje pełną kontrolę nad skrzynką, więc ląduje w Keychain / Keystore.
class SecureSomfyStore implements SomfyStore {
  SecureSomfyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'somfy_gateway';

  @override
  Future<SomfyGateway?> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      return SomfyGateway.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(SomfyGateway gateway) =>
      _storage.write(key: _key, value: jsonEncode(gateway.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
