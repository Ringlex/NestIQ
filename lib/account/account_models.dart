import 'package:flutter/material.dart';

/// Błąd odpowiedzi serwera albo brak połączenia (`status == 0`).
class ApiException implements Exception {
  const ApiException(this.status, this.code, {this.retryAt});

  final int status;
  final String code;

  /// Do kiedy trwa blokada po serii pomyłek (kod `locked`).
  final DateTime? retryAt;

  bool get isNetwork => status == 0;

  String get message {
    switch (code) {
      case 'network':
        return 'Brak połączenia z serwerem. Sprawdź internet i spróbuj ponownie.';
      case 'invalid_email':
        return 'Podaj poprawny adres e-mail, np. anna@wp.pl.';
      case 'invalid_password':
        return 'Hasło musi mieć od 8 do 128 znaków.';
      case 'email_taken':
        return 'Ten adres ma już konto. Zaloguj się.';
      case 'invalid_credentials':
        return 'Nieprawidłowy e-mail lub hasło.';
      case 'email_not_verified':
        return 'Najpierw potwierdź adres e-mail kodem z wiadomości.';
      case 'invalid_code':
        return 'Nieprawidłowy lub wygasły kod. Poproś o nowy.';
      case 'too_soon':
        return 'Poczekaj minutę przed kolejnym kodem.';
      case 'mail_failed':
        return 'Nie udało się wysłać wiadomości. Spróbuj za chwilę.';
      case 'invalid_pin':
        return 'Nieprawidłowy PIN.';
      case 'locked':
        final left = retryAt?.difference(DateTime.now()).inMinutes;
        return left == null || left < 1
            ? 'Za dużo prób. Spróbuj ponownie za chwilę.'
            : 'Za dużo prób. Spróbuj ponownie za ${left + 1} min.';
      case 'admin_required':
        return 'Ta czynność wymaga profilu administratora.';
      case 'last_admin':
        return 'Musi zostać przynajmniej jeden administrator.';
      case 'too_many_profiles':
        return 'Osiągnięto limit ośmiu profili.';
      case 'session_expired':
        return 'Sesja wygasła. Zaloguj się ponownie.';
      default:
        return 'Coś poszło nie tak. Spróbuj ponownie.';
    }
  }

  @override
  String toString() => 'ApiException($status, $code)';
}

enum ProfileRole {
  admin('admin', 'Administrator'),
  member('member', 'Domownik'),
  restricted('restricted', 'Ograniczony');

  const ProfileRole(this.wire, this.label);
  final String wire;
  final String label;

  static ProfileRole fromWire(String? value) => values
      .firstWhere((r) => r.wire == value, orElse: () => ProfileRole.restricted);
}

/// Uprawnienia profilu. Aplikacja je egzekwuje, bo sterowanie urządzeniami
/// odbywa się lokalnie; serwer pilnuje tylko profili i PIN-ów.
class Permissions {
  const Permissions({
    required this.controlLights,
    required this.controlBlinds,
    required this.controlHeating,
    required this.runScenes,
    required this.editScenes,
    required this.manageSettings,
  });

  /// [role] podaje wartość domyślną dla uprawnień, których serwer jeszcze nie zna
  /// (profile zapisane przed dodaniem ogrzewania).
  factory Permissions.fromJson(Map<String, dynamic> json,
          {ProfileRole? role}) =>
      Permissions(
        controlLights: json['controlLights'] == true,
        controlBlinds: json['controlBlinds'] == true,
        controlHeating: json['controlHeating'] is bool
            ? json['controlHeating'] as bool
            : (role != null && preset(role).controlHeating),
        runScenes: json['runScenes'] == true,
        editScenes: json['editScenes'] == true,
        manageSettings: json['manageSettings'] == true,
      );

  static const none = Permissions(
    controlLights: false,
    controlBlinds: false,
    controlHeating: false,
    runScenes: false,
    editScenes: false,
    manageSettings: false,
  );

  /// Domyślne uprawnienia roli – tak samo jak na serwerze.
  static Permissions preset(ProfileRole role) => switch (role) {
        ProfileRole.admin => const Permissions(
            controlLights: true,
            controlBlinds: true,
            controlHeating: true,
            runScenes: true,
            editScenes: true,
            manageSettings: true,
          ),
        ProfileRole.member => const Permissions(
            controlLights: true,
            controlBlinds: true,
            controlHeating: true,
            runScenes: true,
            editScenes: false,
            manageSettings: false,
          ),
        ProfileRole.restricted => const Permissions(
            controlLights: true,
            controlBlinds: true,
            controlHeating: false,
            runScenes: false,
            editScenes: false,
            manageSettings: false,
          ),
      };

  final bool controlLights;
  final bool controlBlinds;
  final bool controlHeating;
  final bool runScenes;
  final bool editScenes;
  final bool manageSettings;

  Permissions copyWith(
          {bool? controlLights,
          bool? controlBlinds,
          bool? controlHeating,
          bool? runScenes}) =>
      Permissions(
        controlLights: controlLights ?? this.controlLights,
        controlBlinds: controlBlinds ?? this.controlBlinds,
        controlHeating: controlHeating ?? this.controlHeating,
        runScenes: runScenes ?? this.runScenes,
        editScenes: editScenes,
        manageSettings: manageSettings,
      );

  Map<String, dynamic> toJson() => {
        'controlLights': controlLights,
        'controlBlinds': controlBlinds,
        'controlHeating': controlHeating,
        'runScenes': runScenes,
        'editScenes': editScenes,
        'manageSettings': manageSettings,
      };
}

class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.color,
    required this.role,
    required this.hasPin,
    required this.permissions,
    this.allowedRooms,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String,
        role: ProfileRole.fromWire(json['role'] as String?),
        hasPin: json['hasPin'] == true,
        permissions: Permissions.fromJson(
          (json['permissions'] as Map?)?.cast<String, dynamic>() ?? const {},
          role: ProfileRole.fromWire(json['role'] as String?),
        ),
        allowedRooms: (json['allowedRooms'] as List?)?.cast<String>(),
      );

  final String id;
  final String name;

  /// `#RRGGBB`.
  final String color;
  final ProfileRole role;
  final bool hasPin;
  final Permissions permissions;

  /// `null` = wszystkie pokoje.
  final List<String>? allowedRooms;

  bool get isAdmin => role == ProfileRole.admin;

  String get letter => name.isEmpty ? '?' : name.characters.first.toUpperCase();

  Color get background => parseColor(color);

  Color get foreground => foregroundFor(background);

  static Color parseColor(String hex) {
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    return Color(0xFF000000 | (value ?? 0xB9EBF3));
  }

  static Color foregroundFor(Color background) =>
      background.computeLuminance() > 0.45
          ? const Color(0xFF171D1E)
          : Colors.white;

  /// Kolory awatarów do wyboru przy tworzeniu profilu.
  static const palette = [
    '#B9EBF3',
    '#FFE3A8',
    '#D9E3F8',
    '#F9D6E0',
    '#D5EBC9',
  ];
}
