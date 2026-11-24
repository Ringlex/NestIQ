import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class GatewayCredentials {
  const GatewayCredentials(
      {required this.host, required this.login, required this.password});
  final String host;
  final String login;
  final String password;
}

/// Dane logowania do bramki trzymane w Keychain / Android Keystore.
class CredentialsStore {
  CredentialsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _host = 'gateway_host';
  static const _login = 'gateway_login';
  static const _password = 'gateway_password';

  Future<GatewayCredentials?> load() async {
    try {
      final values = await _storage.readAll();
      final host = values[_host],
          login = values[_login],
          password = values[_password];
      if (host == null || login == null || password == null) return null;
      return GatewayCredentials(host: host, login: login, password: password);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(GatewayCredentials c) async {
    await _storage.write(key: _host, value: c.host);
    await _storage.write(key: _login, value: c.login);
    await _storage.write(key: _password, value: c.password);
  }

  Future<void> clear() async {
    await _storage.delete(key: _password);
  }

  /// Ostatnio użyty adres i login – do wypełnienia formularza po wylogowaniu.
  Future<(String?, String?)> lastHostAndLogin() async {
    try {
      return (
        await _storage.read(key: _host),
        await _storage.read(key: _login)
      );
    } catch (_) {
      return (null, null);
    }
  }
}
