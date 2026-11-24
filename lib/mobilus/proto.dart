// Minimalna, ręczna implementacja protobuf (proto2) dla wiadomości bramki
// Mobilus Cosmo GTW. Schematy odpowiadają plikom .proto z projektu
// zpieslak/mobilus-client (licencja MIT).
import 'dart:convert';
import 'dart:typed_data';

class _Writer {
  final BytesBuilder _out = BytesBuilder();

  void _varint(int value) {
    // int64 – liczby ujemne kodowane jako 10 bajtów (uzupełnienie do dwóch).
    var v = value;
    for (var i = 0; i < 10; i++) {
      final byte = v & 0x7f;
      v = v >>> 7;
      if (v == 0) {
        _out.addByte(byte);
        return;
      }
      _out.addByte(byte | 0x80);
    }
  }

  void _tag(int field, int wireType) => _varint((field << 3) | wireType);

  void int64(int field, int? value) {
    if (value == null) return;
    _tag(field, 0);
    _varint(value);
  }

  void bytes(int field, List<int>? value) {
    if (value == null) return;
    _tag(field, 2);
    _varint(value.length);
    _out.add(value);
  }

  void string(int field, String? value) {
    if (value == null) return;
    bytes(field, utf8.encode(value));
  }

  Uint8List toBytes() => _out.toBytes();
}

class _Field {
  _Field(this.number, this.wireType, this.intValue, this.bytesValue);
  final int number;
  final int wireType;
  final int intValue;
  final Uint8List? bytesValue;

  String get asString =>
      utf8.decode(bytesValue ?? const [], allowMalformed: true);
  bool get asBool => intValue != 0;
}

/// Parsuje płaską listę pól; rzuca [FormatException] przy uszkodzonych danych.
List<_Field> _parse(Uint8List data) {
  final fields = <_Field>[];
  var pos = 0;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= data.length || shift > 63) {
        throw const FormatException('Nieprawidłowy varint');
      }
      final byte = data[pos++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  while (pos < data.length) {
    final key = readVarint();
    final number = key >> 3;
    final wireType = key & 0x7;
    switch (wireType) {
      case 0:
        fields.add(_Field(number, wireType, readVarint(), null));
      case 1:
        if (pos + 8 > data.length) throw const FormatException('Ucięte dane');
        final v =
            ByteData.sublistView(data, pos, pos + 8).getInt64(0, Endian.little);
        pos += 8;
        fields.add(_Field(number, wireType, v, null));
      case 2:
        final len = readVarint();
        if (len < 0 || pos + len > data.length) {
          throw const FormatException('Ucięte dane');
        }
        fields.add(_Field(
            number, wireType, 0, Uint8List.sublistView(data, pos, pos + len)));
        pos += len;
      case 5:
        if (pos + 4 > data.length) throw const FormatException('Ucięte dane');
        final v =
            ByteData.sublistView(data, pos, pos + 4).getInt32(0, Endian.little);
        pos += 4;
        fields.add(_Field(number, wireType, v, null));
      default:
        throw FormatException('Nieobsługiwany typ pola: $wireType');
    }
  }
  return fields;
}

// ---------------------------------------------------------------- wiadomości

sealed class MobilusMessage {
  const MobilusMessage();
  Uint8List encode() => Uint8List(0);
}

class LoginRequest extends MobilusMessage {
  const LoginRequest({required this.login, required this.password});
  final String login;

  /// SHA-256 hasła użytkownika (nie samo hasło).
  final List<int> password;

  @override
  Uint8List encode() => (_Writer()
        ..string(1, login)
        ..bytes(2, password))
      .toBytes();
}

class LoginResponse extends MobilusMessage {
  const LoginResponse({
    this.loginStatus,
    this.privateKey,
    this.publicKey,
    this.admin,
    this.serialNumber,
    this.userId,
  });

  final int? loginStatus;
  final Uint8List? privateKey;
  final Uint8List? publicKey;
  final bool? admin;
  final String? serialNumber;
  final int? userId;

  bool get isAuthenticated => loginStatus != 1 && privateKey != null;

  factory LoginResponse.decode(Uint8List data) {
    int? status, userId;
    Uint8List? priv, pub;
    bool? admin;
    String? serial;
    for (final f in _parse(data)) {
      switch (f.number) {
        case 1:
          status = f.intValue;
        case 2:
          priv = f.bytesValue;
        case 3:
          pub = f.bytesValue;
        case 4:
          admin = f.asBool;
        case 5:
          serial = f.asString;
        case 6:
          userId = f.intValue;
      }
    }
    return LoginResponse(
      loginStatus: status,
      privateKey: priv,
      publicKey: pub,
      admin: admin,
      serialNumber: serial,
      userId: userId,
    );
  }
}

class DevicesListRequest extends MobilusMessage {
  const DevicesListRequest();
}

class Device {
  const Device({
    required this.id,
    required this.name,
    required this.type,
    this.icon,
    this.favourite = false,
  });

  final int id;
  final String name;
  final int type;
  final int? icon;
  final bool favourite;

  factory Device.decode(Uint8List data) {
    var id = 0, type = 0;
    var name = '';
    int? icon;
    var fav = false;
    for (final f in _parse(data)) {
      switch (f.number) {
        case 1:
          id = f.intValue;
        case 2:
          name = f.asString;
        case 3:
          type = f.intValue;
        case 4:
          icon = f.intValue;
        case 6:
          fav = f.asBool;
      }
    }
    return Device(id: id, name: name, type: type, icon: icon, favourite: fav);
  }
}

class DevicesListResponse extends MobilusMessage {
  const DevicesListResponse(this.devices);
  final List<Device> devices;

  factory DevicesListResponse.decode(Uint8List data) => DevicesListResponse([
        for (final f in _parse(data))
          if (f.number == 1 && f.bytesValue != null)
            Device.decode(f.bytesValue!),
      ]);
}

/// Zdarzenie urządzenia – wspólny format dla CallEvent i CurrentStateEvent.
class DeviceEvent {
  const DeviceEvent({
    this.id,
    required this.deviceId,
    this.eventNumber,
    required this.value,
    this.platform,
    this.user,
    this.insertTime,
  });

  /// Numer zdarzenia dla komendy sterującej wysyłanej przez klienta.
  static const commandEventNumber = 6;

  /// Numer zdarzenia oznaczający, że urządzenie jest w ruchu.
  static const movingEventNumber = 7;

  /// Stan urządzenia (odpowiedź na CurrentStateRequest i powiadomienia).
  static const stateEventNumber = 8;

  /// Zmiana konfiguracji bramki, np. scen (`ADD`, `MODIFY`), bez urządzenia.
  static const configEventNumber = 5;

  /// Powiadomienie o sesji (np. `EXPIRED`), bez identyfikatora urządzenia.
  static const sessionEventNumber = 10;

  final int? id;
  final int deviceId;
  final int? eventNumber;
  final String value;
  final int? platform;
  final int? user;
  final int? insertTime;

  Uint8List encode() => (_Writer()
        ..int64(1, id)
        ..int64(2, deviceId)
        ..int64(3, eventNumber)
        ..string(4, value)
        ..int64(5, platform)
        ..int64(6, user)
        ..int64(7, insertTime))
      .toBytes();

  factory DeviceEvent.decode(Uint8List data) {
    int? id, eventNumber, platform, user, insertTime;
    var deviceId = 0;
    var value = '';
    for (final f in _parse(data)) {
      switch (f.number) {
        case 1:
          id = f.intValue;
        case 2:
          deviceId = f.intValue;
        case 3:
          eventNumber = f.intValue;
        case 4:
          value = f.asString;
        case 5:
          platform = f.intValue;
        case 6:
          user = f.intValue;
        case 7:
          insertTime = f.intValue;
      }
    }
    return DeviceEvent(
      id: id,
      deviceId: deviceId,
      eventNumber: eventNumber,
      value: value,
      platform: platform,
      user: user,
      insertTime: insertTime,
    );
  }
}

List<DeviceEvent> _decodeEvents(Uint8List data) => [
      for (final f in _parse(data))
        if (f.number == 1 && f.bytesValue != null)
          DeviceEvent.decode(f.bytesValue!),
    ];

/// Komenda sterująca. Bramka odsyła ją też jako powiadomienie o zmianie stanu.
class CallEventsRequest extends MobilusMessage {
  const CallEventsRequest(this.events);
  final List<DeviceEvent> events;

  @override
  Uint8List encode() {
    final w = _Writer();
    for (final e in events) {
      w.bytes(1, e.encode());
    }
    return w.toBytes();
  }

  factory CallEventsRequest.decode(Uint8List data) =>
      CallEventsRequest(_decodeEvents(data));
}

class CurrentStateRequest extends MobilusMessage {
  const CurrentStateRequest();
}

class CurrentStateResponse extends MobilusMessage {
  const CurrentStateResponse(this.events);
  final List<DeviceEvent> events;

  factory CurrentStateResponse.decode(Uint8List data) =>
      CurrentStateResponse(_decodeEvents(data));
}

class ScenesListRequest extends MobilusMessage {
  const ScenesListRequest();
}

/// Pora uruchomienia sceny z harmonogramu bramki.
class SceneSchedule {
  const SceneSchedule({required this.day, required this.time});

  /// Harmonogram z dni i godziny w czasie lokalnym telefonu. Bramka liczy
  /// w UTC, więc godzina blisko północy może przesunąć dzień tygodnia.
  static List<SceneSchedule> fromLocal(
      Set<int> localDays, int hour, int minute) {
    final now = DateTime.now();
    final local = DateTime(now.year, now.month, now.day, hour, minute);
    final utc = local.toUtc();
    final shift = DateTime.utc(utc.year, utc.month, utc.day)
        .difference(DateTime.utc(local.year, local.month, local.day))
        .inDays;
    return [
      for (final d in localDays.toList()..sort())
        SceneSchedule(day: (d + shift) % 7, time: utc.hour * 100 + utc.minute),
    ];
  }

  /// Dzień tygodnia w czasie lokalnym (odwrotność przesunięcia z [fromLocal]).
  int get localDay {
    final t = localTime, u = t.toUtc();
    final shift = DateTime.utc(t.year, t.month, t.day)
        .difference(DateTime.utc(u.year, u.month, u.day))
        .inDays;
    return (day + shift) % 7;
  }

  /// Dzień tygodnia w UTC: 0 = niedziela, 1 = poniedziałek … 6 = sobota.
  final int day;

  /// Godzina w UTC zapisana jako GGMM, np. 1530 = 15:30 UTC.
  final int time;

  int get utcHour => time ~/ 100;
  int get utcMinute => time % 100;

  /// Godzina uruchomienia w lokalnej strefie czasowej telefonu (dziś).
  DateTime get localTime {
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day, utcHour, utcMinute)
        .toLocal();
  }

  factory SceneSchedule.decode(Uint8List data) {
    var day = 0, time = 0;
    for (final f in _parse(data)) {
      switch (f.number) {
        case 2:
          day = f.intValue;
        case 3:
          time = f.intValue;
      }
    }
    return SceneSchedule(day: day, time: time);
  }

  Uint8List encode(int sceneId) => (_Writer()
        ..int64(1, sceneId)
        ..int64(2, day)
        ..int64(3, time))
      .toBytes();
}

/// Scena zapisana w bramce (konfigurowana w aplikacji Mobilus).
class GatewayScene {
  const GatewayScene({
    required this.id,
    required this.name,
    required this.events,
    required this.schedule,
    required this.active,
    this.kind = 1,
  });

  final int id;
  final String name;

  /// Pole 3 – nieznane, w scenach z aplikacji Mobilus zawsze 1; odsyłamy bez zmian.
  final int kind;

  /// Komendy sceny (event_number = 6), wysyłane razem jednym CallEventsRequest.
  final List<DeviceEvent> events;
  final List<SceneSchedule> schedule;

  /// Scena aktywna (w aplikacji Mobilus można ją wyłączyć).
  final bool active;

  factory GatewayScene.decode(Uint8List data) {
    var id = 0;
    var name = '';
    var active = false;
    var kind = 1;
    final events = <DeviceEvent>[];
    final schedule = <SceneSchedule>[];
    for (final f in _parse(data)) {
      switch (f.number) {
        case 1:
          id = f.intValue;
        case 2:
          name = f.asString;
        case 3:
          kind = f.intValue;
        case 4 when f.bytesValue != null:
          events.add(DeviceEvent.decode(f.bytesValue!));
        case 5 when f.bytesValue != null:
          schedule.add(SceneSchedule.decode(f.bytesValue!));
        case 7:
          active = f.asBool;
      }
    }
    return GatewayScene(
      id: id,
      name: name,
      events: events,
      schedule: schedule,
      active: active,
      kind: kind,
    );
  }

  GatewayScene copyWith({
    int? id,
    String? name,
    List<DeviceEvent>? events,
    List<SceneSchedule>? schedule,
    bool? active,
  }) =>
      GatewayScene(
        id: id ?? this.id,
        name: name ?? this.name,
        events: events ?? this.events,
        schedule: schedule ?? this.schedule,
        active: active ?? this.active,
        kind: kind,
      );

  Uint8List encode() {
    final w = _Writer()
      ..int64(1, id)
      ..string(2, name)
      ..int64(3, kind);
    for (final e in events) {
      w.bytes(4, e.encode());
    }
    for (final s in schedule) {
      w.bytes(5, s.encode(id));
    }
    w.int64(7, active ? 1 : 0);
    return w.toBytes();
  }
}

class ScenesListResponse extends MobilusMessage {
  const ScenesListResponse(this.scenes);
  final List<GatewayScene> scenes;

  factory ScenesListResponse.decode(Uint8List data) => ScenesListResponse([
        for (final f in _parse(data))
          if (f.number == 1 && f.bytesValue != null)
            GatewayScene.decode(f.bytesValue!),
      ]);
}

/// Dodanie (id sceny = 0), zmiana albo usunięcie sceny w bramce.
/// Odpowiedź: [SceneEditResponse].
class SceneEditRequest extends MobilusMessage {
  const SceneEditRequest(GatewayScene this.scene) : removeId = null;

  /// Usunięcie – aplikacja Mobilus wysyła wtedy samo id sceny.
  const SceneEditRequest.remove(int this.removeId) : scene = null;

  final GatewayScene? scene;
  final int? removeId;

  static const _add = 0, _modify = 1, _remove = 2;

  @override
  Uint8List encode() {
    final w = _Writer();
    if (removeId case final id?) {
      return (w
            ..int64(1, _remove)
            ..bytes(2, (_Writer()..int64(1, id)).toBytes()))
          .toBytes();
    }
    final s = scene!;
    return (w
          ..int64(1, s.id == 0 ? _add : _modify)
          ..bytes(2, s.encode()))
        .toBytes();
  }
}

class SceneEditResponse extends MobilusMessage {
  const SceneEditResponse(this.status);

  /// 0 = zapisano.
  final int status;

  bool get ok => status == 0;

  factory SceneEditResponse.decode(Uint8List data) {
    var status = 0;
    for (final f in _parse(data)) {
      if (f.number == 1) status = f.intValue;
    }
    return SceneEditResponse(status);
  }
}
