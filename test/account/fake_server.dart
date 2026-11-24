import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/account/account_store.dart';

class MemoryStore implements AccountStore {
  StoredAccount saved = const StoredAccount();

  @override
  Future<StoredAccount> load() async => saved;

  @override
  Future<void> saveRefreshToken(String token) async => saved = StoredAccount(
      refreshToken: token,
      email: saved.email,
      lastProfileId: saved.lastProfileId);

  @override
  Future<void> saveEmail(String email) async => saved = StoredAccount(
      refreshToken: saved.refreshToken,
      email: email,
      lastProfileId: saved.lastProfileId);

  @override
  Future<void> saveLastProfile(String? id) async => saved = StoredAccount(
      refreshToken: saved.refreshToken, email: saved.email, lastProfileId: id);

  @override
  Future<void> clear() async => saved = StoredAccount(email: saved.email);
}

Map<String, dynamic> profileJson(String id, String name,
        {String role = 'admin',
        bool hasPin = false,
        Map<String, bool>? permissions}) =>
    {
      'id': id,
      'name': name,
      'color': '#B9EBF3',
      'role': role,
      'hasPin': hasPin,
      'permissions': permissions ??
          {
            'controlLights': true,
            'controlBlinds': true,
            'runScenes': role != 'restricted',
            'editScenes': role == 'admin',
            'manageSettings': role == 'admin',
          },
      'allowedRooms': null,
    };

Map<String, dynamic> sessionJson(String email,
        {String access = 'access-1', String refresh = 'refresh-1'}) =>
    {
      'session': {
        'accessToken': access,
        'refreshToken': refresh,
        'expiresIn': 900,
        'user': {'id': 'u1', 'email': email},
      },
    };

typedef Handler = (int, Map<String, dynamic>)? Function(http.Request request);

/// Atrapa serwera: [handler] zwraca (status, ciało) albo `null`, gdy trasa nieznana.
/// Zapisuje wszystkie żądania w [log] jako `METODA ścieżka`.
class FakeServer {
  FakeServer(this.handler);

  final Handler handler;
  final List<String> log = [];
  final List<http.Request> requests = [];

  late final MockClient client = MockClient((request) async {
    log.add('${request.method} ${request.url.path}');
    requests.add(request);
    final result = handler(request);
    if (result == null) return http.Response('{"error":"not_found"}', 404);
    return http.Response(jsonEncode(result.$2), result.$1,
        headers: {'content-type': 'application/json'});
  });
}
