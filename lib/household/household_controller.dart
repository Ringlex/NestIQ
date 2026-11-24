import 'dart:async';

import 'package:flutter/foundation.dart';

import '../account/account_models.dart';
import '../account/nestiq_api.dart';
import 'household_models.dart';

/// Planer domowy: listy zakupów, przypomnienia, kalendarz i wiadomości.
///
/// Dane leżą na serwerze (współdzielone między telefonami domowników), a kontroler
/// trzyma ich kopię i odświeża ją po każdej zmianie. Wszystko dzieje się w imieniu
/// aktualnie wybranego profilu; po zmianie profilu kopia jest czyszczona.
class HouseholdController extends ChangeNotifier {
  HouseholdController({
    required NestIqApi api,
    this.pollInterval = const Duration(seconds: 30),
    this.onNewMessages,
    this.onRemindersChanged,
  }) : _api = api;

  final NestIqApi _api;
  final Duration pollInterval;

  /// Nowe wiadomości od innych profili wykryte podczas odpytywania (do powiadomienia).
  final void Function(List<PlannerMessage> messages)? onNewMessages;

  /// Przypomnienia się zmieniły (do ponownego zaplanowania powiadomień).
  final void Function(List<Reminder> reminders)? onRemindersChanged;

  String? profileId;
  List<PlannerList> lists = const [];
  List<Reminder> reminders = const [];
  List<CalendarEvent> events = const [];
  List<PlannerMessage> messages = const [];
  int unread = 0;
  bool loading = false;
  String? error;
  bool loaded = false;

  Set<String>? _knownMessageIds;
  Timer? _poll;

  // ---------------------------------------------------------------- profil i odświeżanie

  /// Wiąże kontroler z profilem. Zmiana profilu usuwa dane poprzedniego.
  void bind(String? id) {
    if (id == profileId) return;
    profileId = id;
    lists = const [];
    reminders = const [];
    events = const [];
    messages = const [];
    unread = 0;
    loaded = false;
    error = null;
    _knownMessageIds = null;
    notifyListeners();
    // Przypomnienia poprzedniego profilu (także prywatne) nie mogą dalej powiadamiać.
    onRemindersChanged?.call(const []);
    if (id != null) unawaited(refreshAll());
  }

  Future<void> refreshAll() async {
    if (profileId == null) return;
    loading = true;
    notifyListeners();
    try {
      await Future.wait(
          [refreshLists(), refreshReminders(), refreshMessages()]);
      error = null;
      loaded = true;
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshLists() async {
    final json = await _api.call('GET', '/v1/lists');
    lists = [
      for (final l in json['lists'] as List)
        PlannerList.fromJson((l as Map).cast<String, dynamic>()),
    ];
    notifyListeners();
  }

  Future<void> refreshReminders() async {
    final json = await _api.call('GET', '/v1/reminders');
    reminders = [
      for (final r in json['reminders'] as List)
        Reminder.fromJson((r as Map).cast<String, dynamic>()),
    ];
    notifyListeners();
    onRemindersChanged?.call(reminders);
  }

  Future<void> refreshMessages() async {
    final json = await _api.call('GET', '/v1/messages');
    final all = [
      for (final m in json['messages'] as List)
        PlannerMessage.fromJson((m as Map).cast<String, dynamic>()),
    ];
    final known = _knownMessageIds;
    messages = all;
    unread = (json['unread'] as num?)?.toInt() ??
        all.where((m) => !m.read && m.from != profileId).length;
    _knownMessageIds = {for (final m in all) m.id};
    notifyListeners();

    // Pierwsze pobranie to tylko punkt odniesienia: stare wiadomości nie wywołują powiadomień.
    if (known != null) {
      final fresh = [
        for (final m in all)
          if (!known.contains(m.id) && m.from != profileId && !m.read) m
      ];
      if (fresh.isNotEmpty) onNewMessages?.call(fresh);
    }
  }

  /// Wydarzenia z podanego przedziału dni (włącznie).
  Future<void> loadEvents(DateTime from, DateTime to) async {
    final json = await _api.call('GET', '/v1/events',
        query: {'from': formatDay(from), 'to': formatDay(to)});
    events = [
      for (final e in json['events'] as List)
        CalendarEvent.fromJson((e as Map).cast<String, dynamic>()),
    ];
    notifyListeners();
  }

  /// Odpytywanie wiadomości, dopóki aplikacja jest na wierzchu.
  void startPolling() {
    if (_poll != null) return;
    _poll = Timer.periodic(pollInterval, (_) {
      if (profileId != null) unawaited(refreshMessages().catchError((_) {}));
    });
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  bool _disposed = false;

  /// Odpowiedź z serwera może dotrzeć już po zamknięciu kontrolera (np. po zmianie
  /// profilu albo wylogowaniu); wtedy nie ma kogo powiadamiać.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stopPolling();
    super.dispose();
  }

  // ---------------------------------------------------------------- listy zakupów

  Future<void> createList(String name,
      {List<String> sharedWith = const []}) async {
    await _api.call('POST', '/v1/lists',
        body: {'name': name, 'sharedWith': sharedWith});
    await refreshLists();
  }

  Future<void> updateList(String id,
      {String? name, List<String>? sharedWith}) async {
    await _api.call('PATCH', '/v1/lists/$id', body: {
      if (name != null) 'name': name,
      if (sharedWith != null) 'sharedWith': sharedWith,
    });
    await refreshLists();
  }

  Future<void> deleteList(String id) async {
    await _api.call('DELETE', '/v1/lists/$id');
    await refreshLists();
  }

  Future<void> addItem(String listId, String text, {String? quantity}) async {
    await _api.call('POST', '/v1/lists/$listId/items', body: {
      'text': text,
      if (quantity != null && quantity.trim().isNotEmpty) 'quantity': quantity,
    });
    await refreshLists();
  }

  /// Odhaczenie od razu na ekranie, bo w sklepie nie chcemy czekać na sieć;
  /// przy błędzie wracamy do stanu z serwera.
  Future<void> setItemChecked(
      String listId, String itemId, bool checked) async {
    _patchItem(
        listId,
        itemId,
        (i) => i.copyWith(
            checked: checked, checkedBy: profileId, clearCheckedBy: !checked));
    try {
      await _api.call('PATCH', '/v1/lists/$listId/items/$itemId',
          body: {'checked': checked});
    } catch (_) {
      await refreshLists().catchError((_) {});
      rethrow;
    }
  }

  Future<void> deleteItem(String listId, String itemId) async {
    lists = [
      for (final l in lists)
        l.id == listId
            ? l.copyWith(items: l.items.where((i) => i.id != itemId).toList())
            : l,
    ];
    notifyListeners();
    try {
      await _api.call('DELETE', '/v1/lists/$listId/items/$itemId');
    } catch (_) {
      await refreshLists().catchError((_) {});
      rethrow;
    }
  }

  Future<void> clearChecked(String listId) async {
    await _api.call('POST', '/v1/lists/$listId/clear-checked');
    await refreshLists();
  }

  void _patchItem(
      String listId, String itemId, PlannerItem Function(PlannerItem) change) {
    lists = [
      for (final l in lists)
        l.id == listId
            ? l.copyWith(items: [
                for (final i in l.items) i.id == itemId ? change(i) : i
              ])
            : l,
    ];
    notifyListeners();
  }

  // ---------------------------------------------------------------- przypomnienia

  Future<void> createReminder(Reminder reminder) async {
    await _api.call('POST', '/v1/reminders', body: reminder.toJson());
    await refreshReminders();
  }

  Future<void> updateReminder(String id, Reminder reminder) async {
    await _api.call('PATCH', '/v1/reminders/$id', body: reminder.toJson());
    await refreshReminders();
  }

  Future<void> deleteReminder(String id) async {
    await _api.call('DELETE', '/v1/reminders/$id');
    await refreshReminders();
  }

  /// „Zrobione”: serwer wylicza kolejny termin. Dzień wykonania podaje telefon.
  Future<void> completeReminder(String id, {DateTime? now}) async {
    await _api.call('POST', '/v1/reminders/$id/done',
        body: {'doneOn': formatDay(now ?? DateTime.now())});
    await refreshReminders();
  }

  // ---------------------------------------------------------------- kalendarz

  Future<void> createEvent({
    required String title,
    required DateTime startsAt,
    DateTime? endsAt,
    bool allDay = false,
    String? note,
    bool shared = true,
  }) async {
    await _api.call('POST', '/v1/events',
        body: _eventBody(title, startsAt, endsAt, allDay, note, shared));
  }

  Future<void> updateEvent(
    String id, {
    required String title,
    required DateTime startsAt,
    DateTime? endsAt,
    bool allDay = false,
    String? note,
    bool shared = true,
  }) async {
    await _api.call('PATCH', '/v1/events/$id',
        body: _eventBody(title, startsAt, endsAt, allDay, note, shared));
  }

  Future<void> deleteEvent(String id) async {
    await _api.call('DELETE', '/v1/events/$id');
    events = events.where((e) => e.id != id).toList();
    notifyListeners();
  }

  static String _stamp(DateTime d, bool allDay) {
    String two(int v) => v.toString().padLeft(2, '0');
    final day = formatDay(d);
    return allDay ? day : '${day}T${two(d.hour)}:${two(d.minute)}';
  }

  static Map<String, dynamic> _eventBody(String title, DateTime startsAt,
      DateTime? endsAt, bool allDay, String? note, bool shared) {
    return {
      'title': title,
      'note': note,
      'startsAt': _stamp(startsAt, allDay),
      'endsAt': endsAt == null ? null : _stamp(endsAt, allDay),
      'allDay': allDay,
      'shared': shared,
    };
  }

  // ---------------------------------------------------------------- wiadomości

  Future<void> sendMessage(String body, {String? to}) async {
    await _api.call('POST', '/v1/messages', body: {'to': to, 'body': body});
    await refreshMessages();
  }

  Future<void> markMessagesRead({List<String>? ids}) async {
    await _api.call('POST', '/v1/messages/read',
        body: ids == null ? {'all': true} : {'ids': ids});
    await refreshMessages();
  }
}
