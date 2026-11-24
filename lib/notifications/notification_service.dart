import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../viessmann/fault_monitor.dart';
import '../viessmann/viessmann_faults.dart';
import '../viessmann/viessmann_models.dart';

/// Ładunek powiadomienia o usterce; po jego dotknięciu otwieramy ekran usterek.
const faultPayload = 'faults';

/// Powiadomienia lokalne o usterkach pieca. Działa też w zadaniu w tle,
/// gdzie aplikacja nie ma żadnego ekranu.
class LocalFaultNotifier implements FaultNotifier {
  LocalFaultNotifier._();

  static final instance = LocalFaultNotifier._();

  static const _channelId = 'faults';

  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<String>.broadcast();
  bool _ready = false;

  /// Dotknięcia powiadomień, gdy aplikacja działa.
  Stream<String> get taps => _taps.stream;

  /// Aplikacja została uruchomiona dotknięciem powiadomienia (zimny start).
  bool launchedFromNotification = false;

  /// Ładunek powiadomienia, które uruchomiło aplikację.
  String? launchPayload;

  /// Wtyczka współdzielona z powiadomieniami planera.
  FlutterLocalNotificationsPlugin get plugin => _plugin;

  Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Zgodę pytamy dopiero przy włączeniu powiadomień, nie przy starcie aplikacji.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null) _taps.add(payload);
      },
    );
    // Push z serwera wskazuje ten kanał po nazwie, więc musi istnieć, zanim przyjdzie pierwszy.
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'messages',
          'Wiadomości',
          description: 'Wiadomości od domowników',
          importance: Importance.high,
        ));
    final launch = await _plugin.getNotificationAppLaunchDetails();
    launchPayload = (launch?.didNotificationLaunchApp ?? false)
        ? launch?.notificationResponse?.payload
        : null;
    launchedFromNotification = launchPayload == faultPayload;
    _ready = true;
  }

  /// Prosi o zgodę na powiadomienia (Android 13+ i iOS). `true`, gdy je mamy.
  Future<bool> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null)
      return await android.requestNotificationsPermission() ?? false;
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null)
      return await ios.requestPermissions(
              alert: true, badge: true, sound: true) ??
          false;
    return false;
  }

  @override
  Future<void> show(HeatingFault fault) async {
    await init();
    await _plugin.show(
      // Stabilny numer na podstawie zdarzenia: to samo zdarzenie nie dubluje powiadomienia.
      fault.id.hashCode & 0x7fffffff,
      faultTitle(fault),
      faultWhat(fault),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Usterki pieca',
          channelDescription:
              'Powiadomienia o usterkach i komunikatach serwisowych pieca',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
      payload: faultPayload,
    );
    if (kDebugMode) debugPrint('Powiadomienie o usterce: ${fault.id}');
  }
}
