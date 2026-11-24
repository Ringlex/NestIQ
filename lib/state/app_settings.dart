import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ustawienia aplikacji zapisywane na urządzeniu.
class AppSettings extends ChangeNotifier {
  static const _themeKey = 'theme_mode';
  static const _confirmScenesKey = 'confirm_scenes';

  ThemeMode themeMode = ThemeMode.system;

  /// Pytaj o potwierdzenie przed uruchomieniem sceny.
  bool confirmScenes = false;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      themeMode = ThemeMode.values.asNameMap()[prefs.getString(_themeKey)] ??
          ThemeMode.system;
      confirmScenes = prefs.getBool(_confirmScenesKey) ?? false;
      notifyListeners();
    } catch (_) {
      // Domyślne ustawienia, gdy pamięć jest niedostępna.
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }

  Future<void> setConfirmScenes(bool value) async {
    confirmScenes = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_confirmScenesKey, value);
  }
}
