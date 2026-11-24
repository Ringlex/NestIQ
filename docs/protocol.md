# Protokół bramki Mobilus Cosmo GTW

Nieoficjalny – odtworzony przez autora `mobilus-client`. Implementacja w
`lib/mobilus/`.

## Transport

- MQTT 3.1.1 po WebSocket: `ws://<IP bramki>:8884/mqtt`, bez TLS.
- Identyfikator klienta MQTT: 6 losowych bajtów jako HEX wielkimi literami,
  np. `0A1B2C3D4E5F`.
- Klient subskrybuje swój identyfikator (odpowiedzi) i `clients`
  (rozgłaszane zmiany stanu), a publikuje na `module`.

## Ramka

| Bajty | Pole                                   |
|-------|----------------------------------------|
| 0–3   | długość nagłówka po tym polu, zawsze 13 (uint32 BE) |
| 4     | kategoria wiadomości                   |
| 5–8   | znacznik czasu Unix (uint32 BE)        |
| 9–14  | identyfikator klienta (6 bajtów)       |
| 15    | platforma, 4                           |
| 16    | kod odpowiedzi, 0                      |
| 17–   | ciało: protobuf (proto2), opcjonalnie szyfrowane |

## Kategorie

| Nr | Wiadomość            | Kierunek | Ciało szyfrowane kluczem |
|----|----------------------|----------|--------------------------|
| 1  | LoginRequest         | →        | brak                     |
| 2  | LoginResponse        | ←        | klucz użytkownika        |
| 3  | DevicesListRequest   | →        | brak                     |
| 4  | DevicesListResponse  | ←        | private_key              |
| 5  | (grupy?) – prośba    | →        | brak, puste ciało        |
| 6  | (grupy?)             | ←        | private_key              |
| 7  | PlacesListRequest    | →        | brak, puste ciało        |
| 8  | PlacesListResponse   | ←        | private_key              |
| 9  | ScenesListRequest    | →        | brak, puste ciało        |
| 10 | ScenesListResponse   | ←        | private_key              |
| 16 | SceneEditRequest     | →        | private_key              |
| 17 | SceneEditResponse    | ←        | private_key              |
| 13 | CallEventsRequest    | →        | private_key              |
| 13 | CallEventsRequest    | ←        | public_key (powiadomienia) |
| 26 | CurrentStateRequest  | →        | brak                     |
| 27 | CurrentStateResponse | ←        | private_key              |

## Szyfrowanie

- Klucz użytkownika = SHA-256(hasło). W `LoginRequest.password` wysyła się
  właśnie ten skrót, nie hasło.
- AES w trybie CFB-128, IV = 12 bajtów zerowych + znacznik czasu z nagłówka (BE).
- `LoginResponse` (`login_status` 1 = błąd) zawiera `private_key` i
  `public_key` na resztę sesji.

## Komendy i stany

`CallEvent { device_id, event_number = 6, value }`, gdzie `value`:
`UP`, `DOWN`, `STOP`, `ON`, `OFF`, `NN%` lub `DOWN:NN$` (pozycja lameli).

W stanie `event_number = 7` oznacza ruch. Wartości `UP` = 100 %, `DOWN` = 0 %.

Kategorie 5–10 odczytane narzędziem `tool/sniff_gateway.dart` z ruchu
aplikacji Mobilus (wysyła je zaraz po zalogowaniu, razem z nieznaną 28 → 29).

## Sceny (kategoria 10)

```
ScenesListResponse { repeated Scene scenes = 1; }
Scene {
  int64  id = 1;
  string name = 2;
  int64  ? = 3;                     // zawsze 1
  repeated CallEvent events = 4;    // device_id, event_number = 6, value
  repeated Schedule schedule = 5;
  bool   active = 7;                // scena aktywna (wyłączana w aplikacji Mobilus)
}
Schedule { int64 scene_id = 1; int64 day = 2; /* 0–6 */ int64 time = 3; /* GGMM w UTC */ }
```

Czas harmonogramu jest w UTC: w aplikacji 6:00 i 17:30 (czas letni, UTC+2)
bramka zwraca jako `400` i `1530`.

Dni: 0 = niedziela, 1 = poniedziałek … 6 = sobota (w UTC – godzina blisko
północy może przesunąć dzień względem czasu lokalnego).

Uruchomienie sceny przez aplikację Mobilus to zwykły `CallEventsRequest` ze
wszystkimi komendami sceny naraz.

### Dodawanie, zmiana i usuwanie (kategoria 16 → 17)

```
SceneEditRequest  { int64 operation = 1; /* 0 dodaj, 1 zmień, 2 usuń */ Scene scene = 2; }
SceneEditResponse { int64 status = 1; /* 0 = OK */ }
```

- Dodanie: `scene.id = 0` (aplikacja wysyła też `id = 0` w zdarzeniach
  i `scene_id = 0` w harmonogramie); bramka nadaje nowe id.
- Zmiana: pełna scena z jej id.
- Usunięcie: `scene` zawiera tylko `id`.

Po każdej zmianie bramka rozgłasza na `clients`
`CallEvent { event_number = 5, value = "ADD" | "MODIFY" | "REMOVE" }` (bez
device_id) – sygnał dla innych klientów, żeby pobrali sceny od nowa.

## Miejsca (kategoria 8)

```
Place { int64 id = 1; string name = 2; int64 ? = 3; repeated int64 device_ids = 4; int64 ? = 6; }
```

## Wygaśnięcie sesji

Bramka wysyła na temat klienta `CallEvent { event_number = 10, value = "EXPIRED" }`
(bez device_id), po czym trzeba zalogować się ponownie.

## Typy urządzeń

| Typ | Nazwa     | Sterowanie                      |
|-----|-----------|---------------------------------|
| 1   | SENSO     | góra/stop/dół + pozycja %       |
| 2   | COSMO     | góra/stop/dół                   |
| 3   | CMR       | góra/stop/dół                   |
| 4   | CGR       | brama garażowa (STOP = `UP`)    |
| 5   | SWITCH    | ON/OFF                          |
| 6   | SWITCH NP | ON/OFF                          |
| 7   | COSMO CZR | góra/stop/dół + lamele          |
| 8   | COSMO MZR | góra/stop/dół                   |
| 9   | SENSO Z   | góra/stop/dół + pozycja %       |
