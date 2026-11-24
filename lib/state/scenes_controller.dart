import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Komenda wysyłana do jednego urządzenia w ramach sceny, np. `UP` lub `50%`.
class SceneAction {
  const SceneAction({required this.deviceId, required this.value});

  final int deviceId;
  final String value;

  Map<String, Object> toJson() => {'device': deviceId, 'value': value};

  factory SceneAction.fromJson(Map<String, dynamic> j) =>
      SceneAction(deviceId: j['device'] as int, value: j['value'] as String);
}

/// Scena: nazwany zestaw komend. Bramka nie przechowuje scen w znanym
/// protokole, więc trzymamy je lokalnie i wysyłamy komendy po kolei.
class Scene {
  const Scene({required this.id, required this.name, required this.actions});

  final String id;
  final String name;
  final List<SceneAction> actions;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'actions': [for (final a in actions) a.toJson()]
      };

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: j['id'] as String,
        name: j['name'] as String,
        actions: [
          for (final a in j['actions'] as List)
            SceneAction.fromJson(a as Map<String, dynamic>)
        ],
      );
}

class ScenesController extends ChangeNotifier {
  static const _key = 'scenes';

  List<Scene> scenes = const [];

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      scenes = [
        for (final s in jsonDecode(raw) as List)
          Scene.fromJson(s as Map<String, dynamic>)
      ];
      notifyListeners();
    } catch (_) {
      // Uszkodzony zapis – zaczynamy od pustej listy.
    }
  }

  /// Dodaje nową scenę albo zastępuje istniejącą o tym samym id.
  Future<void> save(Scene scene) async {
    final i = scenes.indexWhere((s) => s.id == scene.id);
    scenes = [...scenes];
    if (i < 0) {
      scenes.add(scene);
    } else {
      scenes[i] = scene;
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    scenes = scenes.where((s) => s.id != id).toList();
    await _persist();
  }

  Future<void> _persist() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode([for (final s in scenes) s.toJson()]));
  }
}
