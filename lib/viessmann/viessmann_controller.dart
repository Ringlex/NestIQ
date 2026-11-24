import 'dart:async';

import 'package:flutter/widgets.dart';

import 'viessmann_auth.dart';
import 'viessmann_client.dart';
import 'viessmann_models.dart';
import 'viessmann_store.dart';

typedef ViessmannApiFactory = ViessmannApi Function({
  required Future<String> Function() token,
  required void Function() onCall,
});

/// Piec Viessmann przez ViCare: logowanie, odczyt stanu i sterowanie.
///
/// Dzienny limit API to 1450 zapytań na całe konto, więc kontroler sam go pilnuje:
/// odczyt co [pollInterval] tylko przy otwartej zakładce, nie częściej niż co
/// [minRefreshGap], a przy zużyciu ponad [pollBudget] zapytań odświeża już tylko na żądanie.
class ViessmannController extends ChangeNotifier {
  ViessmannController({
    ViessmannStore? store,
    ViessmannAuth? auth,
    ViessmannApiFactory? apiFactory,
    this.pollInterval = const Duration(minutes: 5),
    this.minRefreshGap = const Duration(seconds: 45),
    this.settleDelay = const Duration(seconds: 2),
    bool Function()? isInForeground,
    this.onRefreshed,
  })  : _isInForeground = isInForeground ?? _appInForeground,
        _store = store ?? SecureViessmannStore(),
        _auth = auth ?? ViessmannAuth(),
        _apiFactory = apiFactory ?? _defaultApi;

  static ViessmannApi _defaultApi({
    required Future<String> Function() token,
    required void Function() onCall,
  }) =>
      ViessmannClient(token: token, onCall: onCall);

  /// W tle (aplikacja zminimalizowana) nie odpytujemy, żeby nie zużywać limitu.
  static bool _appInForeground() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.hidden;
  }

  static const dailyLimit = 1450;
  static const pollBudget = 1200;
  static const manualBudget = 1400;

  final ViessmannStore _store;
  final ViessmannAuth _auth;
  final ViessmannApiFactory _apiFactory;
  final Duration pollInterval;
  final Duration minRefreshGap;
  final Duration settleDelay;
  final bool Function() _isInForeground;

  /// Wywoływane po każdym udanym odczycie, np. do wykrywania nowych usterek.
  final Future<void> Function(HeatingState state)? onRefreshed;

  late final ViessmannApi _api =
      _apiFactory(token: _accessToken, onCall: _countCall);

  String? clientId;
  ViessmannDeviceRef? device;
  HeatingState? state;
  String? error;

  /// Sesja wygasła albo została cofnięta: trzeba zalogować się ponownie.
  bool sessionExpired = false;
  bool loaded = false;
  bool busy = false;

  ViessmannTokens? _tokens;
  String? _refreshToken;
  Future<void>? _tokenRefresh;
  Future<void>? _refreshing;
  DateTime? _lastRefresh;
  Timer? _poll;
  List<int> _calls = [];

  bool get isConfigured =>
      clientId != null && _refreshToken != null && device != null;

  /// Liczba zapytań z ostatnich 24 godzin.
  int get callsLast24h {
    _trimCalls();
    return _calls.length;
  }

  // ---------------------------------------------------------------- start

  Future<void> load() async {
    final saved = await _store.load();
    clientId = saved.clientId;
    _refreshToken = saved.refreshToken;
    device = saved.device;
    _calls = [...saved.calls];
    _trimCalls();
    loaded = true;
    notifyListeners();
  }

  /// Logowanie w przeglądarce, wyszukanie pieca i pierwszy odczyt.
  Future<void> connect(String id) async {
    final trimmed = id.trim();
    if (!RegExp(r'^[A-Za-z0-9]{16,64}$').hasMatch(trimmed)) {
      throw const ViessmannException(
          'Client ID to długi ciąg liter i cyfr z portalu deweloperskiego Viessmanna.');
    }
    busy = true;
    error = null;
    sessionExpired = false;
    notifyListeners();
    try {
      final tokens = await _auth.login(trimmed);
      _tokens = tokens;
      clientId = trimmed;
      _refreshToken = tokens.refreshToken;
      await _store.saveSession(
          clientId: trimmed, refreshToken: tokens.refreshToken);

      device = await _api.findHeatingDevice();
      await _store.saveDevice(device!);
      await refresh(force: true);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    stopPolling();
    await _store.clear();
    clientId = null;
    device = null;
    state = null;
    error = null;
    _tokens = null;
    _refreshToken = null;
    _lastRefresh = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- odczyt

  /// Pobiera stan pieca. Bez [force] pomija odczyt, jeśli poprzedni był przed chwilą.
  Future<void> refresh({bool force = false}) {
    if (!isConfigured) return Future.value();
    return _refreshing ??=
        _doRefresh(force).whenComplete(() => _refreshing = null);
  }

  Future<void> _doRefresh(bool force) async {
    final last = _lastRefresh;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < minRefreshGap) return;
    if (callsLast24h >= manualBudget) {
      error =
          'Wykorzystano dzienny limit zapytań do Viessmanna ($dailyLimit). Odczyt wróci jutro.';
      notifyListeners();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      final data = await _api.features(device!);
      final parsed = HeatingState.parse(data);
      state = parsed;
      _lastRefresh = DateTime.now();
      error = null;
      sessionExpired = false;
      try {
        await onRefreshed?.call(parsed);
      } catch (_) {
        // Błąd powiadomienia nie może zepsuć odczytu.
      }
    } on ViessmannException catch (e) {
      error = e.message;
      sessionExpired = e.needsLogin;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Odczyt co [pollInterval], dopóki zakładka jest otwarta.
  void startPolling() {
    if (_poll != null || !isConfigured) return;
    unawaited(refresh());
    _poll = Timer.periodic(pollInterval, (_) {
      if (_isInForeground() && callsLast24h < pollBudget)
        unawaited(refresh(force: true));
    });
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }

  // ---------------------------------------------------------------- sterowanie

  /// Temperatura docelowa ciepłej wody; zakres bierzemy z odpowiedzi pieca.
  Future<void> setDhwTarget(num celsius) async {
    final current = state;
    final command =
        current?.command(HeatingState.dhwTargetFeature, 'setTargetTemperature');
    final range = current?.dhwRange;
    if (command == null || range == null) {
      throw const ViessmannException(
          'Piec nie udostępnia ustawiania temperatury c.w.u.');
    }
    if (celsius < range.min || celsius > range.max) {
      throw ViessmannException(
          'Temperatura c.w.u. musi mieścić się w zakresie ${range.min}–${range.max} °C.');
    }
    await _execute(HeatingState.dhwTargetFeature, command,
        {'temperature': celsius.round()});
  }

  /// Nastawa obiegu grzewczego (temperatura programu normalnego). Piec nie podaje
  /// temperatury w pomieszczeniu, więc to temperatura wody zasilającej.
  Future<void> setCircuitTemperature(num celsius) async {
    final current = state;
    final command =
        current?.command(HeatingState.programNormalFeature, 'setTemperature');
    final range = current?.circuitRange;
    if (command == null || range == null) {
      throw const ViessmannException(
          'Piec nie udostępnia ustawiania nastawy obiegu.');
    }
    if (celsius < range.min || celsius > range.max) {
      throw ViessmannException(
          'Nastawa obiegu musi mieścić się w zakresie ${range.min}–${range.max} °C.');
    }
    await _execute(HeatingState.programNormalFeature, command,
        {'targetTemperature': celsius.round()});
  }

  Future<void> setDhwMode(String mode) async {
    final current = state;
    final command = current?.command(HeatingState.dhwModeFeature, 'setMode');
    if (command == null || !current!.dhwModes.contains(mode)) {
      throw const ViessmannException(
          'Piec nie przyjmuje takiego trybu ciepłej wody.');
    }
    await _execute(HeatingState.dhwModeFeature, command, {'mode': mode});
  }

  Future<void> setHeatingMode(String mode) async {
    final current = state;
    final command =
        current?.command(HeatingState.heatingModeFeature, 'setMode');
    if (command == null || !current!.heatingModes.contains(mode)) {
      throw const ViessmannException(
          'Piec nie przyjmuje takiego trybu ogrzewania.');
    }
    await _execute(HeatingState.heatingModeFeature, command, {'mode': mode});
  }

  Future<void> _execute(
      String feature, FeatureCommand command, Map<String, Object?> body) async {
    if (callsLast24h >= dailyLimit - 5) {
      throw const ViessmannException(
          'Dzienny limit zapytań do Viessmanna jest prawie wyczerpany.');
    }
    busy = true;
    notifyListeners();
    try {
      await _api.execute(device!, command, body, feature: feature);
    } finally {
      busy = false;
      notifyListeners();
    }
    // Piec potwierdza zmianę z opóźnieniem, więc stan odczytujemy chwilę później.
    if (settleDelay > Duration.zero) await Future<void>.delayed(settleDelay);
    await refresh(force: true);
  }

  // ---------------------------------------------------------------- tokeny i limit

  Future<String> _accessToken() async {
    final tokens = _tokens;
    if (tokens != null && !tokens.isExpired) return tokens.accessToken;
    // Równoległe żądania czekają na jedną wymianę tokenu.
    await (_tokenRefresh ??=
        _renewToken().whenComplete(() => _tokenRefresh = null));
    return _tokens!.accessToken;
  }

  Future<void> _renewToken() async {
    final refresh = _refreshToken;
    final id = clientId;
    if (refresh == null || id == null) {
      throw const ViessmannException('Zaloguj się ponownie do Viessmanna.',
          status: 401);
    }
    final renewed = await _auth.refresh(id, refresh);
    _tokens = renewed;
    if (renewed.refreshToken != null && renewed.refreshToken != _refreshToken) {
      _refreshToken = renewed.refreshToken;
      await _store.saveRefreshToken(renewed.refreshToken!);
    }
  }

  void _countCall() {
    _calls.add(DateTime.now().millisecondsSinceEpoch);
    _trimCalls();
    unawaited(_store.saveCalls(_calls));
  }

  void _trimCalls() {
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    _calls.removeWhere((t) => t < cutoff);
  }
}
