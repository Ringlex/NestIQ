import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../household/household_models.dart';
import '../household/reminder_plan.dart';
import 'notification_service.dart';

const messagesPayload = 'planner:messages';

/// Powiadomienia planera: przypomnienia zaplanowane na konkretne dni i
/// natychmiastowe powiadomienia o nowych wiadomościach.
abstract interface class PlannerNotifier {
  /// Zastępuje wszystkie zaplanowane przypomnienia podanym planem.
  Future<void> scheduleReminders(List<PlannedNotification> plan);

  Future<void> showMessages(List<PlannerMessage> messages,
      String Function(String profileId) senderName);
}

class LocalPlannerNotifier implements PlannerNotifier {
  LocalPlannerNotifier(this._service);

  final LocalFaultNotifier _service;
  bool _tzReady = false;

  Future<bool> _ensureTimezone() async {
    if (_tzReady) return true;
    try {
      tz_data.initializeTimeZones();
      tz.setLocalLocation(
          tz.getLocation(await FlutterTimezone.getLocalTimezone()));
      _tzReady = true;
    } catch (_) {
      // Bez strefy czasowej nie wiemy, kiedy jest 9:00, więc niczego nie planujemy.
    }
    return _tzReady;
  }

  static const _reminderChannel = AndroidNotificationDetails(
    'reminders',
    'Przypomnienia',
    channelDescription: 'Filtr do wody, ekspres, ubezpieczenie, urodziny',
    importance: Importance.high,
    priority: Priority.high,
  );

  static const _messageChannel = AndroidNotificationDetails(
    'messages',
    'Wiadomości',
    channelDescription: 'Wiadomości od domowników',
    importance: Importance.high,
    priority: Priority.high,
  );

  @override
  Future<void> scheduleReminders(List<PlannedNotification> plan) async {
    await _service.init();
    if (!await _ensureTimezone()) return;
    final plugin = _service.plugin;

    // Kasujemy tylko własne przypomnienia, żeby nie ruszać powiadomień o usterkach.
    for (final pending in await plugin.pendingNotificationRequests()) {
      if (pending.payload == reminderPayload) await plugin.cancel(pending.id);
    }

    for (final n in plan) {
      await plugin.zonedSchedule(
        n.id,
        n.title,
        n.body,
        tz.TZDateTime.from(n.at, tz.local),
        const NotificationDetails(
          android: _reminderChannel,
          iOS:
              DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
        // Dokładność co do minut nie jest potrzebna, a "inexact" nie wymaga specjalnej zgody Androida.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: n.payload,
      );
    }
  }

  @override
  Future<void> showMessages(
      List<PlannerMessage> messages, String Function(String) senderName) async {
    await _service.init();
    for (final m in messages) {
      await _service.plugin.show(
        stableId('message:${m.id}'),
        senderName(m.from),
        m.body,
        const NotificationDetails(
          android: _messageChannel,
          iOS:
              DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
        payload: messagesPayload,
      );
    }
  }
}
