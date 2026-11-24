import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/mobilus/codec.dart';
import 'package:nestiq/mobilus/proto.dart';

List<int> _varint(int v) {
  final out = <int>[];
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  return out..add(v);
}

List<int> _int(int field, int v) => [..._varint(field << 3), ..._varint(v)];
List<int> _bytes(int field, List<int> b) =>
    [..._varint(field << 3 | 2), ..._varint(b.length), ...b];
List<int> _str(int field, String s) => _bytes(field, utf8.encode(s));

void main() {
  test('lista scen w formacie odczytanym z bramki', () {
    // Odpowiada scenie „Close blinds in the afternoon” z prawdziwej bramki.
    final scene = [
      ..._int(1, 1),
      ..._str(2, 'Close blinds in the afternoon'),
      ..._int(3, 1),
      ..._bytes(4, [..._int(2, 0), ..._int(3, 6), ..._str(4, 'DOWN')]),
      ..._bytes(4, [..._int(2, 1), ..._int(3, 6), ..._str(4, '20%')]),
      for (var day = 0; day < 7; day++)
        ..._bytes(5, [..._int(1, 1), ..._int(2, day), ..._int(3, 1530)]),
      ..._int(7, 1),
    ];
    final off = [..._int(1, 2), ..._str(2, 'Close blinds'), ..._int(7, 0)];
    final r = ScenesListResponse.decode(
        Uint8List.fromList([..._bytes(1, scene), ..._bytes(1, off)]));

    expect(r.scenes.map((s) => s.name),
        ['Close blinds in the afternoon', 'Close blinds']);
    final s = r.scenes.first;
    expect(
        {for (final e in s.events) e.deviceId: e.value}, {0: 'DOWN', 1: '20%'});
    expect(s.schedule.map((x) => x.day), [0, 1, 2, 3, 4, 5, 6]);
    expect((s.schedule.first.utcHour, s.schedule.first.utcMinute), (15, 30));
    final local = s.schedule.first.localTime;
    expect(local.toUtc().hour, 15);
    expect(local.minute, 30);
    expect(s.active, isTrue);
    expect(r.scenes.last.active, isFalse);
  });

  test('zapis sceny ma ten sam format co aplikacja Mobilus', () {
    // Ramka „Close blinds” wysłana przez aplikację Mobilus (zmiana, nieaktywna).
    final expected = [
      ..._int(1, 1),
      ..._bytes(2, [
        ..._int(1, 2),
        ..._str(2, 'Close blinds'),
        ..._int(3, 1),
        for (var d = 0; d < 4; d++)
          ..._bytes(4, [..._int(2, d), ..._int(3, 6), ..._str(4, 'DOWN')]),
        ..._bytes(5, [..._int(1, 2), ..._int(2, 0), ..._int(3, 2130)]),
        ..._bytes(5, [..._int(1, 2), ..._int(2, 1), ..._int(3, 2130)]),
        ..._int(7, 0),
      ]),
    ];
    final scene = GatewayScene(
      id: 2,
      name: 'Close blinds',
      active: false,
      events: [
        for (var d = 0; d < 4; d++)
          DeviceEvent(
              deviceId: d,
              eventNumber: DeviceEvent.commandEventNumber,
              value: 'DOWN'),
      ],
      schedule: const [
        SceneSchedule(day: 0, time: 2130),
        SceneSchedule(day: 1, time: 2130)
      ],
    );
    expect(SceneEditRequest(scene).encode(), expected);

    // Usunięcie: operacja 2 i samo id – jak „test” usunięty w aplikacji Mobilus.
    expect(const SceneEditRequest.remove(4).encode(),
        [..._int(1, 2), ..._bytes(2, _int(1, 4))]);

    // Nowa scena: operacja 0 i id 0.
    final added = SceneEditRequest(scene.copyWith(id: 0)).encode();
    expect(added.sublist(0, 2), _int(1, 0));
  });

  test('zapis sceny jest szyfrowany kluczem sesji (kategoria 16)', () {
    final keys = KeyRing('x')..privateKey = Uint8List(32);
    const scene = GatewayScene(
        id: 4, name: 'test', active: true, events: [], schedule: []);
    final frame = MobilusCodec.encode(const SceneEditRequest(scene),
        clientId: '0A1B2C3D4E5F', keys: keys, timestamp: 1);
    expect(frame[4], 16);
    expect(frame.sublist(17), isNot(const SceneEditRequest(scene).encode()));
  });

  test('harmonogram: czas lokalny ↔ UTC i dni tygodnia', () {
    // Wszystkie dni i dowolna godzina wracają bez zmian.
    for (final (h, m) in [(0, 15), (6, 0), (17, 30), (23, 45)]) {
      final s = SceneSchedule.fromLocal({0, 1, 2, 3, 4, 5, 6}, h, m);
      expect({for (final x in s) x.day}, hasLength(7));
      expect((s.first.localTime.hour, s.first.localTime.minute), (h, m));
    }
    // Pojedynczy dzień też wraca jako ten sam dzień lokalny, nawet przy północy.
    for (final (h, m) in [(0, 30), (12, 0), (23, 30)]) {
      final s = SceneSchedule.fromLocal({1}, h, m).single;
      expect(s.localDay, 1);
      final now = DateTime.now();
      final utc = DateTime(now.year, now.month, now.day, h, m).toUtc();
      expect(s.time, utc.hour * 100 + utc.minute);
    }
  });

  test('prośba o sceny to kategoria 9 z pustym ciałem', () {
    final frame = MobilusCodec.encode(const ScenesListRequest(),
        clientId: '0A1B2C3D4E5F', keys: KeyRing('x'), timestamp: 1);
    expect(frame[4], 9);
    expect(frame.length, 17);
  });
}
