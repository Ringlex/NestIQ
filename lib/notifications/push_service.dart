import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Powiadomienia push z serwera (FCM): wiadomości od domowników docierają także
/// wtedy, gdy aplikacja jest zamknięta.
abstract interface class PushService {
  /// `android` albo `ios`; serwer używa tego do wyboru formatu wiadomości.
  String get platform;

  /// Token tego urządzenia, `null` gdy push jest niedostępny (brak konfiguracji
  /// Firebase, brak zgody, brak Usług Google).
  Future<String?> token();

  /// Token zmienił się i serwer musi dostać nowy.
  Stream<String> get tokenRefreshes;

  /// Push przyszedł, gdy aplikacja jest na ekranie (system wtedy sam niczego nie pokazuje).
  Stream<PushEvent> get foreground;

  /// Użytkownik dotknął powiadomienia, także tego, które uruchomiło aplikację.
  Stream<PushEvent> get opened;
}

class PushEvent {
  const PushEvent(this.type);

  /// `message` dla wiadomości od domownika.
  final String? type;
}

/// Brak push: testy, platformy bez Firebase i aplikacja bez `google-services.json`.
class NoPushService implements PushService {
  const NoPushService();

  @override
  String get platform => 'android';

  @override
  Future<String?> token() async => null;

  @override
  Stream<String> get tokenRefreshes => const Stream.empty();

  @override
  Stream<PushEvent> get foreground => const Stream.empty();

  @override
  Stream<PushEvent> get opened => const Stream.empty();
}

class FirebasePushService implements PushService {
  FirebasePushService._(this._messaging);

  final FirebaseMessaging _messaging;

  /// Zwraca [NoPushService], gdy Firebase nie da się uruchomić, więc brak
  /// konfiguracji nigdy nie wywraca startu aplikacji.
  static Future<PushService> start() async {
    try {
      await Firebase.initializeApp();
      return FirebasePushService._(FirebaseMessaging.instance);
    } catch (_) {
      return const NoPushService();
    }
  }

  @override
  String get platform => Platform.isIOS ? 'ios' : 'android';

  @override
  Future<String?> token() async {
    try {
      // Zgodę na powiadomienia pyta już LocalFaultNotifier; tu tylko jej dopilnowujemy (iOS).
      await _messaging.requestPermission();
      return await _messaging.getToken();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Stream<PushEvent> get foreground => FirebaseMessaging.onMessage.map(_event);

  @override
  Stream<PushEvent> get opened async* {
    final initial = await _messaging.getInitialMessage();
    if (initial != null) yield _event(initial);
    yield* FirebaseMessaging.onMessageOpenedApp.map(_event);
  }

  PushEvent _event(RemoteMessage m) => PushEvent(m.data['type'] as String?);
}
