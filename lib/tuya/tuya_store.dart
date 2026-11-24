import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'tuya_models.dart';

class StoredTuya {
  const StoredTuya(
      {this.credentials, this.devices = const [], this.mode = TuyaMode.auto});

  final TuyaCloudCredentials? credentials;
  final List<TuyaDevice> devices;
  final TuyaMode mode;
}

/// Dane Tuya na telefonie. Klucze lokalne i sekret chmury są poufne, więc
/// trafiają do Keychain / Android Keystore, a nie do zwykłych preferencji.
abstract class TuyaStore {
  Future<StoredTuya> load();
  Future<void> saveCredentials(TuyaCloudCredentials? credentials);
  Future<void> saveDevices(List<TuyaDevice> devices);
  Future<void> saveMode(TuyaMode mode);
}

class SecureTuyaStore implements TuyaStore {
  SecureTuyaStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _credentials = 'tuya_credentials';
  static const _devices = 'tuya_devices';
  static const _mode = 'tuya_mode';

  @override
  Future<StoredTuya> load() async {
    try {
      final values = await _storage.readAll();
      final credentials = values[_credentials];
      final devices = values[_devices];
      return StoredTuya(
        credentials: credentials == null
            ? null
            : TuyaCloudCredentials.fromJson(
                jsonDecode(credentials) as Map<String, dynamic>),
        devices: devices == null
            ? const []
            : [
                for (final d in jsonDecode(devices) as List)
                  TuyaDevice.fromJson((d as Map).cast<String, dynamic>()),
              ],
        mode: TuyaMode.fromName(values[_mode]),
      );
    } catch (_) {
      return const StoredTuya();
    }
  }

  @override
  Future<void> saveCredentials(TuyaCloudCredentials? credentials) =>
      credentials == null
          ? _storage.delete(key: _credentials)
          : _storage.write(
              key: _credentials, value: jsonEncode(credentials.toJson()));

  @override
  Future<void> saveDevices(List<TuyaDevice> devices) => _storage.write(
      key: _devices, value: jsonEncode([for (final d in devices) d.toJson()]));

  @override
  Future<void> saveMode(TuyaMode mode) =>
      _storage.write(key: _mode, value: mode.name);
}
