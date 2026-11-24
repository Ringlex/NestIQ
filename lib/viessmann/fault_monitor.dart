import 'package:shared_preferences/shared_preferences.dart';

import 'viessmann_models.dart';

/// Pokazuje powiadomienie o usterce.
abstract interface class FaultNotifier {
  Future<void> show(HeatingFault fault);
}

/// Stan potrzebny, żeby nie powiadamiać drugi raz o tym samym: to, o czym już
/// wiemy, oraz czy powiadomienia są włączone. Trzymany w SharedPreferences, bo
/// działa też w zadaniu w tle, gdzie nie ma ekranów ani kontrolerów aplikacji.
abstract class FaultStore {
  Future<bool> enabled();
  Future<void> setEnabled(bool value);

  /// `null`, dopóki nie zapisano pierwszej wiedzy o piecu.
  Future<Set<String>?> seen();
  Future<void> saveSeen(Set<String> ids);

  /// Zapomina stan, więc kolejny odczyt znów będzie tylko punktem odniesienia.
  Future<void> clearSeen();
}

class PrefsFaultStore implements FaultStore {
  static const _enabled = 'fault_notifications';
  static const _seen = 'fault_seen';

  @override
  Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabled) ?? false;

  @override
  Future<void> setEnabled(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_enabled, value);

  @override
  Future<Set<String>?> seen() async {
    final list = (await SharedPreferences.getInstance()).getStringList(_seen);
    return list?.toSet();
  }

  @override
  Future<void> saveSeen(Set<String> ids) async =>
      (await SharedPreferences.getInstance())
          .setStringList(_seen, ids.toList());

  @override
  Future<void> clearSeen() async =>
      (await SharedPreferences.getInstance()).remove(_seen);
}

/// Porównuje bieżący stan pieca z tym, o czym już powiadomiono.
///
/// - Pierwszy odczyt po włączeniu tylko zapamiętuje stan (bez powiadomień), żeby
///   stare wpisy w piecu nie zasypały użytkownika.
/// - Dalej powiadamia raz o każdej nowej usterce.
/// - Usterka, która zniknęła, jest zapominana, więc jej powrót znów powiadomi.
class FaultMonitor {
  FaultMonitor({required this.store, required this.notifier});

  final FaultStore store;
  final FaultNotifier notifier;

  /// Zwraca usterki, o których właśnie powiadomiono.
  Future<List<HeatingFault>> process(HeatingState state) async {
    if (!await store.enabled()) return const [];

    final known = await store.seen();
    final current = {for (final f in state.faults) f.id};

    if (known == null) {
      await store.saveSeen(current);
      return const [];
    }

    final fresh = [
      for (final f in state.alerts)
        if (!known.contains(f.id)) f
    ];
    // Zapisujemy najpierw: gdyby powiadomienie padło, nie zasypiemy użytkownika przy kolejnym odczycie.
    await store.saveSeen(current);
    for (final fault in fresh) {
      await notifier.show(fault);
    }
    return fresh;
  }

  /// Po wyłączeniu powiadomień zapominamy stan, żeby po ponownym włączeniu
  /// obowiązywał nowy punkt odniesienia.
  Future<void> reset() => store.clearSeen();
}
