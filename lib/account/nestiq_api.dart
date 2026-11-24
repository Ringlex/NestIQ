import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'account_models.dart';

/// Adres serwera. Do pracy z lokalnym `wrangler dev` (z emulatora Androida):
/// `--dart-define=NESTIQ_API=http://10.0.2.2:8787`.
const nestIqApiUrl = String.fromEnvironment(
  'NESTIQ_API',
  defaultValue: 'https://nestiq-api.pitstop-garage.workers.dev',
);

class AuthSession {
  const AuthSession({required this.email});
  final String email;
}

/// Klient serwera kont i profili (`backend/`).
///
/// Trzyma tokeny, sam odświeża wygasły token dostępu (raz, z rotacją tokenu
/// odświeżającego) i zgłasza utratę sesji przez [onSessionExpired].
class NestIqApi {
  NestIqApi({String baseUrl = nestIqApiUrl, http.Client? client})
      : _baseUrl = baseUrl,
        _http = client ?? http.Client();

  final String _baseUrl;
  final http.Client _http;

  String? accessToken;
  String? refreshToken;

  /// Wywoływane przy każdej rotacji, żeby nowy token trafił do magazynu.
  void Function(String refreshToken)? onRefreshToken;

  /// Odświeżenie się nie udało i serwer odrzucił token (nie: brak sieci).
  void Function()? onSessionExpired;

  Future<void>? _refreshing;

  static const _timeout = Duration(seconds: 15);

  // ---- konto

  Future<void> register(String email, String password) => _send(
      'POST', '/v1/auth/register', {'email': email, 'password': password});

  Future<AuthSession> verify(String email, String code) async {
    final json =
        await _send('POST', '/v1/auth/verify', {'email': email, 'code': code});
    return _takeSession(json);
  }

  Future<void> resend(String email) =>
      _send('POST', '/v1/auth/resend', {'email': email});

  Future<AuthSession> login(String email, String password) async {
    final json = await _send(
        'POST', '/v1/auth/login', {'email': email, 'password': password});
    return _takeSession(json);
  }

  Future<void> forgotPassword(String email) =>
      _send('POST', '/v1/auth/password/forgot', {'email': email});

  Future<void> resetPassword(String email, String code, String newPassword) =>
      _send('POST', '/v1/auth/password/reset',
          {'email': email, 'code': code, 'newPassword': newPassword});

  /// Wymienia zapisany token odświeżający na świeżą sesję (start aplikacji).
  Future<void> restoreSession() => _refresh();

  Future<void> signOut() async {
    final token = refreshToken;
    accessToken = null;
    refreshToken = null;
    if (token == null) return;
    try {
      await _send('POST', '/v1/auth/sign-out', {'refreshToken': token});
    } on ApiException {
      // Wylogowanie lokalne i tak się udało; serwer wyczyści token po wygaśnięciu.
    }
  }

  // ---- powiadomienia push

  Future<void> registerPush(String token, String platform) =>
      _send('POST', '/v1/push/register', {'token': token, 'platform': platform},
          auth: true);

  // ---- profile

  Future<List<Profile>> listProfiles() async {
    final json = await _send('GET', '/v1/profiles', null, auth: true);
    return (json['profiles'] as List)
        .map((p) => Profile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  /// Zwraca profil; dla pierwszego profilu serwer od razu zwraca też token z jego wyborem.
  Future<Profile> createProfile(Map<String, dynamic> body) async {
    final json = await _send('POST', '/v1/profiles', body, auth: true);
    final token = json['accessToken'] as String?;
    if (token != null) accessToken = token;
    return Profile.fromJson(json['profile'] as Map<String, dynamic>);
  }

  Future<Profile> updateProfile(String id, Map<String, dynamic> body) async {
    final json = await _send('PATCH', '/v1/profiles/$id', body, auth: true);
    return Profile.fromJson(json['profile'] as Map<String, dynamic>);
  }

  Future<void> deleteProfile(String id) =>
      _send('DELETE', '/v1/profiles/$id', null, auth: true);

  Future<Profile> selectProfile(String id, {String? pin}) async {
    final json = await _send(
        'POST', '/v1/profiles/$id/select', {if (pin != null) 'pin': pin},
        auth: true);
    accessToken = json['accessToken'] as String;
    return Profile.fromJson(json['profile'] as Map<String, dynamic>);
  }

  /// `pin == null` zdejmuje PIN (reset przez administratora).
  Future<void> setPin(String id, String? pin) =>
      _send('PUT', '/v1/profiles/$id/pin', {'pin': pin}, auth: true);

  Future<void> recoverPin(String id, {required String password, String? pin}) =>
      _send('POST', '/v1/profiles/$id/pin/recover',
          {'password': password, if (pin != null) 'pin': pin},
          auth: true);

  // ---- ogólne wywołanie dla modułów domowych (planer)

  /// Wywołanie z tokenem konta i wybranego profilu; zwraca ciało odpowiedzi.
  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) {
    final qs = query == null || query.isEmpty
        ? ''
        : '?${Uri(queryParameters: query).query}';
    return _send(method, '$path$qs', body, auth: true);
  }

  // ---- wewnętrzne

  AuthSession _takeSession(Map<String, dynamic> json) {
    final session = json['session'] as Map<String, dynamic>;
    accessToken = session['accessToken'] as String;
    refreshToken = session['refreshToken'] as String;
    onRefreshToken?.call(refreshToken!);
    return AuthSession(email: (session['user'] as Map)['email'] as String);
  }

  Future<void> _refresh() {
    // Równoległe żądania, które trafiły na 401, czekają na jedną wymianę.
    // Druga wymiana tym samym tokenem uniewazniłaby całą rodzinę tokenów.
    return _refreshing ??= () async {
      final token = refreshToken;
      if (token == null) throw const ApiException(401, 'session_expired');
      try {
        final json =
            await _send('POST', '/v1/auth/refresh', {'refreshToken': token});
        _takeSession(json);
      } on ApiException catch (e) {
        if (!e.isNetwork) {
          accessToken = null;
          refreshToken = null;
          onSessionExpired?.call();
          throw const ApiException(401, 'session_expired');
        }
        rethrow;
      }
    }()
        .whenComplete(() => _refreshing = null);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body, {
    bool auth = false,
    bool retried = false,
  }) async {
    final request = http.Request(method, Uri.parse('$_baseUrl$path'))
      ..headers['content-type'] = 'application/json';
    if (auth && accessToken != null)
      request.headers['authorization'] = 'Bearer $accessToken';
    if (body != null) request.body = jsonEncode(body);

    http.Response response;
    try {
      response = await http.Response.fromStream(
          await _http.send(request).timeout(_timeout));
    } on Exception {
      throw const ApiException(0, 'network');
    }

    Map<String, dynamic> decoded = const {};
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is Map<String, dynamic>) decoded = parsed;
    } catch (_) {
      // Pusta albo nie-JSON-owa odpowiedź – status wystarczy.
    }

    // Tylko wygasły token dostępu (`unauthorized`). Inne 401 to odpowiedzi
    // merytoryczne, np. zły PIN, i odświeżanie niczego by nie zmieniło.
    if (response.statusCode == 401 &&
        decoded['error'] == 'unauthorized' &&
        auth &&
        !retried &&
        refreshToken != null) {
      await _refresh();
      return _send(method, path, body, auth: auth, retried: true);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        decoded['error'] as String? ?? 'unknown',
        retryAt:
            DateTime.tryParse(decoded['retryAt'] as String? ?? '')?.toLocal(),
      );
    }
    return decoded;
  }
}
