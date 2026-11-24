/// Skrzynka Somfy TaHoma z włączonym trybem dewelopera.
class SomfyGateway {
  const SomfyGateway(
      {required this.id, required this.host, required this.token});

  factory SomfyGateway.fromJson(Map<String, dynamic> json) => SomfyGateway(
      id: json['id'] as String,
      host: json['host'] as String,
      token: json['token'] as String);

  /// Numer PIN skrzynki, np. `2001-1234-5678`.
  final String id;
  final String host;

  /// Token z menu „Tryb dewelopera”: pełny dostęp do skrzynki, więc w Keychain/Keystore.
  final String token;

  Map<String, dynamic> toJson() => {'id': id, 'host': host, 'token': token};
}

/// Roleta, markiza, brama itp. widziana przez TaHoma.
class SomfyCover {
  const SomfyCover({
    required this.url,
    required this.name,
    required this.available,
    this.closure,
    this.openClosed,
    this.canSetPosition = false,
    this.stopCommand,
  });

  /// Adres urządzenia w skrzynce, np. `io://2001-1234-5678/12345678`.
  final String url;
  final String name;
  final bool available;

  /// Zamknięcie w % (0 = otwarta, 100 = zamknięta) z `core:ClosureState`.
  final int? closure;

  /// `open` albo `closed` z `core:OpenClosedState`.
  final String? openClosed;
  final bool canSetPosition;

  /// `stop` albo `my` (dla silników RTS), `null` gdy urządzenie nie ma żadnego.
  final String? stopCommand;

  /// Otwarcie w %, 100 = otwarta, zgodnie z resztą aplikacji.
  int? get position {
    if (closure != null) return 100 - closure!.clamp(0, 100);
    return switch (openClosed) {
      'open' => 100,
      'closed' => 0,
      _ => null,
    };
  }

  SomfyCover withClosure(int closure) => SomfyCover(
        url: url,
        name: name,
        available: available,
        closure: closure,
        openClosed: openClosed,
        canSetPosition: canSetPosition,
        stopCommand: stopCommand,
      );
}
