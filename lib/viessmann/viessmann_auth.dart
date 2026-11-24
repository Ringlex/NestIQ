import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import 'viessmann_models.dart';

const viessmannIam = 'https://iam.viessmann-climatesolutions.com/idp/v3';

/// Otwiera stronę logowania i zwraca adres, na który użytkownik wrócił.
typedef ViessmannBrowser = Future<String> Function(
    String url, String callbackScheme);

Future<String> _systemBrowser(String url, String callbackScheme) =>
    FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: callbackScheme);

/// Logowanie do konta ViCare: OAuth2 z kodem autoryzacyjnym i PKCE, bez sekretu
/// klienta. Hasło do ViCare wpisuje się tylko na stronie Viessmanna.
class ViessmannAuth {
  ViessmannAuth(
      {http.Client? client, ViessmannBrowser? browser, Random? random})
      : _http = client ?? http.Client(),
        _browser = browser ?? _systemBrowser,
        _random = random ?? Random.secure();

  final http.Client _http;
  final ViessmannBrowser _browser;
  final Random _random;

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  String _randomString(int bytes) =>
      _base64Url(List.generate(bytes, (_) => _random.nextInt(256)));

  static String codeChallenge(String verifier) =>
      _base64Url(sha256.convert(utf8.encode(verifier)).bytes);

  static Uri authorizeUri(
          {required String clientId,
          required String challenge,
          required String state}) =>
      Uri.parse('$viessmannIam/authorize').replace(queryParameters: {
        'client_id': clientId,
        'redirect_uri': viessmannRedirectUri,
        // offline_access daje token odświeżający, więc logowanie nie powtarza się co godzinę.
        'scope': 'IoT User offline_access',
        'response_type': 'code',
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
        'state': state,
      });

  Future<ViessmannTokens> login(String clientId) async {
    final verifier = _randomString(48);
    final state = _randomString(16);
    final url = authorizeUri(
        clientId: clientId, challenge: codeChallenge(verifier), state: state);

    // Przed otwarciem przeglądarki sprawdzamy, czy Viessmann przyjmie klienta i adres
    // przekierowania. Inaczej użytkownik zobaczyłby błąd w przeglądarce i wrócił z niczym.
    await _preflight(url);

    final String callback;
    try {
      callback = await _browser(url.toString(), viessmannCallbackScheme);
    } on PlatformException catch (e) {
      throw ViessmannException(
        e.code == 'CANCELED'
            ? 'Logowanie zostało przerwane (zamknięto przeglądarkę).'
            : 'Nie udało się dokończyć logowania: ${e.code}${e.message == null ? '' : ' (${e.message})'}.',
      );
    } on Exception catch (e) {
      throw ViessmannException('Nie udało się dokończyć logowania: $e');
    }

    final query = Uri.parse(callback).queryParameters;
    if (query['error'] != null) {
      throw ViessmannException(
        'Viessmann odrzucił logowanie: ${query['error_description'] ?? query['error']}',
      );
    }
    if (query['state'] != state || query['code'] == null) {
      throw const ViessmannException(
          'Niepoprawna odpowiedź logowania. Spróbuj ponownie.');
    }

    return _token({
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'redirect_uri': viessmannRedirectUri,
      'code': query['code']!,
      'code_verifier': verifier,
    });
  }

  /// Viessmann odrzuca zły Client ID albo niezarejestrowany adres przekierowania
  /// kodem 400 jeszcze przed stroną logowania. Wtedy mówimy o tym wprost.
  /// Brak sieci i inne niespodzianki ignorujemy: logowanie ruszy normalnie.
  Future<void> _preflight(Uri url) async {
    try {
      final request = http.Request('GET', url)..followRedirects = false;
      final response = await http.Response.fromStream(
          await _http.send(request).timeout(const Duration(seconds: 10)));
      if (response.statusCode != 400) return;
      final json = jsonDecode(response.body);
      final description =
          json is Map ? '${json['error_description'] ?? json['error']}' : '';
      if (description.toLowerCase().contains('redirection uri')) {
        throw const ViessmannException(
          'Viessmann nie zna adresu przekierowania $viessmannRedirectUri. '
          'Dodaj go w portalu deweloperskim: My Dashboard → Twój klient → Redirect URIs.',
        );
      }
      if (description.isNotEmpty) {
        throw ViessmannException(
            'Viessmann odrzucił logowanie: $description. Sprawdź Client ID.');
      }
    } on ViessmannException {
      rethrow;
    } catch (_) {
      // Nie udało się sprawdzić, więc próbujemy zalogować normalnie.
    }
  }

  /// Wymiana tokenu odświeżającego; stary token jest wymieniany na nowy, jeśli serwer go zwróci.
  Future<ViessmannTokens> refresh(String clientId, String refreshToken) async {
    final tokens = await _token({
      'grant_type': 'refresh_token',
      'client_id': clientId,
      'refresh_token': refreshToken,
    });
    return ViessmannTokens(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken ?? refreshToken,
      expiresAt: tokens.expiresAt,
    );
  }

  Future<ViessmannTokens> _token(Map<String, String> form) async {
    final http.Response response;
    try {
      response = await _http
          .post(Uri.parse('$viessmannIam/token'), body: form)
          .timeout(const Duration(seconds: 20));
    } on Exception {
      throw const ViessmannException('Brak połączenia z Viessmannem.');
    }

    Map<String, dynamic> json = const {};
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    if (response.statusCode != 200 || json['access_token'] is! String) {
      final detail = json['error_description'] ??
          json['error'] ??
          'HTTP ${response.statusCode}';
      throw ViessmannException(
        form['grant_type'] == 'refresh_token'
            ? 'Sesja Viessmanna wygasła. Zaloguj się ponownie ($detail).'
            : 'Logowanie nie powiodło się: $detail',
        status: response.statusCode == 200 ? 401 : response.statusCode,
      );
    }

    return ViessmannTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: DateTime.now().add(
          Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600)),
    );
  }
}
