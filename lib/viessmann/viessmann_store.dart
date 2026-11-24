import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'viessmann_models.dart';

class StoredViessmann {
  const StoredViessmann(
      {this.clientId, this.refreshToken, this.device, this.calls = const []});

  final String? clientId;
  final String? refreshToken;
  final ViessmannDeviceRef? device;

  /// Czasy (ms od epoki) zapytań z ostatniej doby, do pilnowania dziennego limitu.
  final List<int> calls;
}

abstract class ViessmannStore {
  Future<StoredViessmann> load();
  Future<void> saveSession(
      {required String clientId, required String? refreshToken});
  Future<void> saveRefreshToken(String refreshToken);
  Future<void> saveDevice(ViessmannDeviceRef device);
  Future<void> saveCalls(List<int> calls);
  Future<void> clear();
}

/// Token odświeżający daje dostęp do konta ViCare, więc trafia do Keychain / Keystore.
class SecureViessmannStore implements ViessmannStore {
  SecureViessmannStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _clientId = 'viessmann_client_id';
  static const _refresh = 'viessmann_refresh_token';
  static const _device = 'viessmann_device';
  static const _calls = 'viessmann_calls';

  @override
  Future<StoredViessmann> load() async {
    try {
      final values = await _storage.readAll();
      final prefs = await SharedPreferences.getInstance();
      final device = values[_device];
      return StoredViessmann(
        clientId: values[_clientId],
        refreshToken: values[_refresh],
        device: device == null
            ? null
            : ViessmannDeviceRef.fromJson(
                jsonDecode(device) as Map<String, dynamic>),
        calls: (prefs.getStringList(_calls) ?? const [])
            .map(int.tryParse)
            .whereType<int>()
            .toList(),
      );
    } catch (_) {
      return const StoredViessmann();
    }
  }

  @override
  Future<void> saveSession(
      {required String clientId, required String? refreshToken}) async {
    await _storage.write(key: _clientId, value: clientId);
    if (refreshToken != null)
      await _storage.write(key: _refresh, value: refreshToken);
  }

  @override
  Future<void> saveRefreshToken(String refreshToken) =>
      _storage.write(key: _refresh, value: refreshToken);

  @override
  Future<void> saveDevice(ViessmannDeviceRef device) =>
      _storage.write(key: _device, value: jsonEncode(device.toJson()));

  @override
  Future<void> saveCalls(List<int> calls) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_calls, [for (final c in calls) '$c']);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _refresh);
    await _storage.delete(key: _device);
    await _storage.delete(key: _clientId);
  }
}
