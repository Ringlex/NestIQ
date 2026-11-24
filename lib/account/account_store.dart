import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredAccount {
  const StoredAccount({this.refreshToken, this.email, this.lastProfileId});

  final String? refreshToken;
  final String? email;
  final String? lastProfileId;
}

/// Sesja konta trzymana między uruchomieniami.
abstract class AccountStore {
  Future<StoredAccount> load();
  Future<void> saveRefreshToken(String token);
  Future<void> saveEmail(String email);
  Future<void> saveLastProfile(String? id);
  Future<void> clear();
}

/// Keychain / Android Keystore, jak dane logowania do bramki.
class SecureAccountStore implements AccountStore {
  SecureAccountStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _refresh = 'account_refresh_token';
  static const _email = 'account_email';
  static const _lastProfile = 'account_last_profile';

  @override
  Future<StoredAccount> load() async {
    try {
      final values = await _storage.readAll();
      return StoredAccount(
        refreshToken: values[_refresh],
        email: values[_email],
        lastProfileId: values[_lastProfile],
      );
    } catch (_) {
      return const StoredAccount();
    }
  }

  @override
  Future<void> saveRefreshToken(String token) =>
      _storage.write(key: _refresh, value: token);

  @override
  Future<void> saveEmail(String email) =>
      _storage.write(key: _email, value: email);

  @override
  Future<void> saveLastProfile(String? id) => id == null
      ? _storage.delete(key: _lastProfile)
      : _storage.write(key: _lastProfile, value: id);

  /// Zostawia e-mail, żeby formularz logowania był po wylogowaniu wypełniony.
  @override
  Future<void> clear() async {
    await _storage.delete(key: _refresh);
    await _storage.delete(key: _lastProfile);
  }
}
