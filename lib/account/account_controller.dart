import 'dart:async';

import 'package:flutter/foundation.dart';

import '../notifications/push_service.dart';
import 'account_models.dart';
import 'account_store.dart';
import 'nestiq_api.dart';

enum AccountPhase {
  restoring,

  /// Serwer nieosiągalny przy starcie – zapisana sesja czeka na ponowną próbę.
  offline,
  signedOut,
  awaitingVerification,

  /// Konto bez profilu: tworzymy pierwszy, administratora.
  needsProfile,
  choosingProfile,
  active,
}

/// Konto domu i wybrany profil domownika.
///
/// Metody zmieniające dane rzucają [ApiException] – ekrany pokazują jej
/// [ApiException.message] przy formularzu. Kontroler trzyma tylko stan.
class AccountController extends ChangeNotifier {
  AccountController({NestIqApi? api, AccountStore? store, PushService? push})
      : api = api ?? NestIqApi(),
        _store = store ?? SecureAccountStore(),
        _push = push ?? const NoPushService() {
    this.api.onRefreshToken =
        (token) => unawaited(_store.saveRefreshToken(token));
    this.api.onSessionExpired = _expire;
    _tokenRefreshes = _push.tokenRefreshes.listen((token) {
      if (this.api.refreshToken != null) unawaited(_sendPushToken(token));
    });
  }

  final NestIqApi api;
  final AccountStore _store;
  final PushService _push;
  StreamSubscription<String>? _tokenRefreshes;

  AccountPhase phase = AccountPhase.restoring;
  String? email;
  String? pendingEmail;
  List<Profile> profiles = const [];
  Profile? active;

  Permissions get permissions => active?.permissions ?? Permissions.none;
  bool get isAdmin => active?.isAdmin ?? false;

  /// Adres wpisany przy ostatnim logowaniu – do wypełnienia formularza.
  Future<String?> lastEmail() async => (await _store.load()).email;

  // ---- start

  Future<void> restore() async {
    final saved = await _store.load();
    email = saved.email;
    if (saved.refreshToken == null) {
      _setPhase(AccountPhase.signedOut);
      return;
    }
    api.refreshToken = saved.refreshToken;
    try {
      await api.restoreSession();
      await _afterSignIn(lastProfileId: saved.lastProfileId);
    } on ApiException catch (e) {
      if (e.isNetwork) {
        _setPhase(AccountPhase.offline);
      } else {
        _expire();
      }
    }
  }

  // ---- konto

  Future<void> register(String email, String password) async {
    await api.register(email, password);
    pendingEmail = email;
    _setPhase(AccountPhase.awaitingVerification);
  }

  Future<void> verify(String code) async {
    final target = pendingEmail ?? email;
    if (target == null) return;
    final session = await api.verify(target, code);
    await _signedIn(session.email);
  }

  Future<void> resendCode() async {
    final target = pendingEmail ?? email;
    if (target != null) await api.resend(target);
  }

  /// Wraca do formularza logowania z ekranu potwierdzania adresu.
  void cancelVerification() {
    pendingEmail = null;
    _setPhase(AccountPhase.signedOut);
  }

  Future<void> login(String email, String password) async {
    try {
      final session = await api.login(email, password);
      await _signedIn(session.email);
    } on ApiException catch (e) {
      if (e.code != 'email_not_verified') rethrow;
      // Konto czeka na kod – wysyłamy nowy i przechodzimy do jego wpisania.
      pendingEmail = email;
      try {
        await api.resend(email);
      } on ApiException {
        // Kod mógł zostać wysłany przed chwilą; użytkownik może poprosić ponownie.
      }
      _setPhase(AccountPhase.awaitingVerification);
    }
  }

  Future<void> forgotPassword(String email) => api.forgotPassword(email);

  Future<void> resetPassword(String email, String code, String newPassword) =>
      api.resetPassword(email, code, newPassword);

  Future<void> logout() async {
    await api.signOut();
    await _store.clear();
    _reset(AccountPhase.signedOut);
  }

  Future<void> retry() => restore();

  // ---- profile

  Future<void> reloadProfiles() async {
    profiles = await api.listProfiles();
    final current = active;
    if (current != null) {
      active = profiles.where((p) => p.id == current.id).firstOrNull;
    }
    notifyListeners();
  }

  /// Pierwszy profil konta (administrator) – serwer od razu go wybiera.
  Future<void> createFirstProfile(
      {required String name, required String color, String? pin}) async {
    final profile = await api.createProfile(
        {'name': name, 'color': color, if (pin != null) 'pin': pin});
    profiles = [profile];
    await _enter(profile);
  }

  Future<Profile> createProfile({
    required String name,
    required String color,
    required ProfileRole role,
    required Permissions permissions,
    List<String>? allowedRooms,
    String? pin,
  }) async {
    final profile = await api.createProfile({
      'name': name,
      'color': color,
      'role': role.wire,
      'permissions': permissions.toJson(),
      'allowedRooms': allowedRooms,
      if (pin != null) 'pin': pin,
    });
    await reloadProfiles();
    return profile;
  }

  Future<void> updateProfile(
    String id, {
    String? name,
    String? color,
    ProfileRole? role,
    Permissions? permissions,
    List<String>? allowedRooms,
    bool resetRooms = false,
  }) async {
    await api.updateProfile(id, {
      if (name != null) 'name': name,
      if (color != null) 'color': color,
      if (role != null) 'role': role.wire,
      if (permissions != null) 'permissions': permissions.toJson(),
      if (allowedRooms != null || resetRooms) 'allowedRooms': allowedRooms,
    });
    await reloadProfiles();
  }

  Future<void> deleteProfile(String id) async {
    await api.deleteProfile(id);
    await reloadProfiles();
    // Usunięcie własnego profilu odsyła do wyboru.
    if (active == null && phase == AccountPhase.active) {
      await _store.saveLastProfile(null);
      _setPhase(AccountPhase.choosingProfile);
    }
  }

  Future<void> setPin(String id, String? pin) async {
    await api.setPin(id, pin);
    await reloadProfiles();
  }

  Future<void> recoverPin(String id,
      {required String password, String? pin}) async {
    await api.recoverPin(id, password: password, pin: pin);
    await reloadProfiles();
  }

  /// Wybór profilu na tym urządzeniu; przy profilu z PIN-em serwer go sprawdza.
  Future<void> selectProfile(String id, {String? pin}) async {
    final profile = await api.selectProfile(id, pin: pin);
    await _enter(profile);
  }

  /// Wyjście do ekranu wyboru bez wylogowania z konta.
  void switchProfile() {
    active = null;
    unawaited(_store.saveLastProfile(null));
    _setPhase(AccountPhase.choosingProfile);
  }

  // ---- wewnętrzne

  Future<void> _signedIn(String signedEmail) async {
    email = signedEmail;
    pendingEmail = null;
    await _store.saveEmail(signedEmail);
    await _afterSignIn();
  }

  /// Push to dodatek: nieudana rejestracja tokenu nie może blokować logowania.
  Future<void> _sendPushToken(String token) async {
    try {
      await api.registerPush(token, _push.platform);
    } on ApiException {
      // Następne logowanie albo odświeżenie tokenu spróbuje ponownie.
    }
  }

  Future<void> _registerPush() async {
    final token = await _push.token();
    if (token != null) await _sendPushToken(token);
  }

  Future<void> _afterSignIn({String? lastProfileId}) async {
    profiles = await api.listProfiles();
    unawaited(_registerPush());
    if (profiles.isEmpty) {
      _setPhase(AccountPhase.needsProfile);
      return;
    }
    // Wracamy prosto do ostatniego profilu, o ile nie ma PIN-u – to ta sama
    // osoba na tym samym telefonie, pytanie "kto korzysta?" byłoby uciążliwe.
    final last = profiles.where((p) => p.id == lastProfileId).firstOrNull;
    if (last != null && !last.hasPin) {
      try {
        await selectProfile(last.id);
        return;
      } on ApiException {
        // Wybór ręczny poniżej.
      }
    }
    _setPhase(AccountPhase.choosingProfile);
  }

  Future<void> _enter(Profile profile) async {
    active = profile;
    await _store.saveLastProfile(profile.id);
    _setPhase(AccountPhase.active);
  }

  void _expire() {
    unawaited(_store.clear());
    _reset(AccountPhase.signedOut);
  }

  @override
  void dispose() {
    _tokenRefreshes?.cancel();
    super.dispose();
  }

  void _reset(AccountPhase next) {
    active = null;
    profiles = const [];
    pendingEmail = null;
    api.accessToken = null;
    api.refreshToken = null;
    _setPhase(next);
  }

  void _setPhase(AccountPhase next) {
    phase = next;
    notifyListeners();
  }
}
