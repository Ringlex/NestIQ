import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Room {
  const Room({required this.id, required this.name});

  factory Room.fromJson(Map<String, dynamic> json) =>
      Room(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// Pokoje i przypisanie do nich urządzeń.
///
/// Bramka Mobilus nie zna pojęcia pokoju, więc to podział aplikacji, zapisany
/// na telefonie. Identyfikatory pokoi trafiają do profili jako lista dozwolonych.
class RoomsController extends ChangeNotifier {
  static const _key = 'rooms_v1';

  List<Room> rooms = const [];

  /// Klucz urządzenia → identyfikator pokoju. Klucze: `m:<id>` dla Mobilus,
  /// `t:<id urządzenia>:<dp>` dla przycisku włącznika Tuya, `s:...` dla Shelly.
  final Map<String, String> _assignments = {};

  static String mobilusKey(int deviceId) => 'm:$deviceId';

  static String tuyaKey(String deviceId, int dpId) => 't:$deviceId:$dpId';

  /// Czujnik Tuya (cały czujnik, nie pojedynczy punkt danych): `t:<id>:sensor`.
  static String tuyaSensorKey(String deviceId) => 't:$deviceId:sensor';

  /// Urządzenie Somfy TaHoma: `o:<id skrzynki>:<deviceURL>`.
  static String somfyKey(String gatewayId, String deviceUrl) =>
      'o:$gatewayId:$deviceUrl';

  /// Światło Philips Hue: `h:<id mostka>:<id światła>`.
  static String hueKey(String bridgeId, String lightId) =>
      'h:$bridgeId:$lightId';

  /// Kanał urządzenia Shelly: `s:<id urządzenia>:<rodzaj>:<numer>`.
  static String shellyKey(String deviceId, String kind, int id) =>
      's:$deviceId:$kind:$id';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      rooms = [
        for (final r in json['rooms'] as List)
          Room.fromJson(r as Map<String, dynamic>)
      ];
      _assignments
        ..clear()
        ..addAll({
          for (final e in (json['assignments'] as Map<String, dynamic>).entries)
            // Starsze zapisy miały same numery urządzeń Mobilus.
            (int.tryParse(e.key) != null ? 'm:${e.key}' : e.key):
                e.value as String,
        });
      notifyListeners();
    } catch (_) {
      // Uszkodzony zapis traktujemy jak brak pokoi.
    }
  }

  Room? byId(String id) => rooms.where((r) => r.id == id).firstOrNull;

  String? roomOfKey(String key) => _assignments[key];

  String? roomOf(int mobilusDeviceId) =>
      _assignments[mobilusKey(mobilusDeviceId)];

  List<String> keysIn(String roomId) => [
        for (final e in _assignments.entries)
          if (e.value == roomId) e.key
      ];

  Future<Room> add(String name) async {
    final room = Room(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: name.trim());
    rooms = [...rooms, room];
    await _save();
    return room;
  }

  Future<void> rename(String id, String name) async {
    rooms = [
      for (final r in rooms) r.id == id ? Room(id: id, name: name.trim()) : r
    ];
    await _save();
  }

  Future<void> remove(String id) async {
    rooms = rooms.where((r) => r.id != id).toList();
    _assignments.removeWhere((_, room) => room == id);
    await _save();
  }

  /// `roomId == null` zdejmuje urządzenie z pokoju.
  Future<void> assignKey(String key, String? roomId) async {
    if (roomId == null) {
      _assignments.remove(key);
    } else {
      _assignments[key] = roomId;
    }
    await _save();
  }

  Future<void> assign(int mobilusDeviceId, String? roomId) =>
      assignKey(mobilusKey(mobilusDeviceId), roomId);

  Future<void> _save() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'rooms': [for (final r in rooms) r.toJson()],
        'assignments': _assignments,
      }),
    );
  }
}
