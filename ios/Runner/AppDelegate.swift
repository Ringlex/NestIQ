import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications
import workmanager

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Zadanie w tle (sprawdzanie usterek pieca) działa w osobnym silniku Fluttera,
    // który też musi znać wtyczki: powiadomienia, magazyn danych, sieć.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    // Powiadomienia mają się pokazywać także, gdy aplikacja jest na wierzchu.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate

    // iOS sam decyduje, kiedy faktycznie obudzić aplikację; to tylko prośba o możliwie częste wybudzanie.
    UIApplication.shared.setMinimumBackgroundFetchInterval(TimeInterval(60 * 30))

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
