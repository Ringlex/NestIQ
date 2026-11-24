# NestIQ

Aplikacja Flutter (Android / iOS) do sterowania roletami Mobilus COSMO 2WAY
przez bramkę **Mobilus Cosmo GTW** w sieci lokalnej – bez chmury producenta.

## Co działa

- Wyszukiwanie bramki w sieci Wi‑Fi (skan podsieci /24 na porcie 8884
  z potwierdzeniem MQTT po WebSocket); bez zapamiętanego adresu pierwsza
  znaleziona bramka wpisuje się sama.
- Logowanie do bramki (adres IP, użytkownik, hasło), opcja „Zapamiętaj mnie”
  (dane w Keychain / Android Keystore, automatyczne logowanie przy starcie).
- Pobranie listy sparowanych urządzeń i ich bieżącego stanu.
- Sterowanie: Góra / Stop / Dół, suwak pozycji (SENSO), włącz/wyłącz (SWITCH).
- Zmiany stanu na żywo (bramka rozgłasza je również po użyciu pilota).
- Dolny pasek: Dom (urządzenia), Sceny, Użytkownik, Ustawienia.
- Sceny z bramki (te same co w aplikacji Mobilus): uruchamianie, tworzenie,
  edycja (nazwa, aktywna, godzina, dni, komendy dla rolet) i usuwanie;
  szybkie akcje „wszystkie w górę / w dół / stop”.
- Ustawienia: motyw (systemowy / jasny / ciemny), potwierdzanie scen.
- Ponowne łączenie po utracie połączenia, odświeżanie gestem „pull to refresh”.

## Konto, profile i uprawnienia

- Logowanie i rejestracja e-mailem i hasłem (dowolna skrzynka), potwierdzenie
  adresu 6-cyfrowym kodem, reset hasła kodem z maila.
- Po zalogowaniu wybór profilu domownika („Kto korzysta?”). Pierwszy profil
  konta jest zawsze administratorem. Profil może mieć PIN, sprawdzany na
  serwerze z blokadą po 5 pomyłkach; administrator resetuje PIN innego profilu.
- Role: administrator, domownik, ograniczony (Dziecko: włącza i wyłącza
  światła i rolety, bez scen i ustawień). Zakładki Sceny i Ustawienia pojawiają
  się tylko profilom z uprawnieniami.
- Ekran Dom: zakładki Oświetlenie / Rolety, urządzenia pogrupowane w pokoje
  (pokoje zapisane na telefonie, bo bramka Mobilus ich nie zna).
- Oświetlenie to przełączniki Mobilus (SWITCH) i włączniki Wi‑Fi Tuya.
- Backend: `backend/` (Cloudflare Worker + D1), wdrożony pod
  `https://nestiq-api.pitstop-garage.workers.dev`. Do pracy z lokalnym
  `wrangler dev`: `--dart-define=NESTIQ_API=http://10.0.2.2:8787`.

## Planer domowy

Zakładka **Planer** (dla każdego profilu): zakupy, przypomnienia, kalendarz, wiadomości. Dane trzyma serwer (`backend/`, trasy poniżej), więc domownicy widzą to samo.

- **Zakupy** - listy z pozycjami, odhaczanie, „Usuń kupione”. Właściciel listy może ją udostępnić wybranym profilom (te dopisują i odhaczają; zmiana nazwy, udostępnienie i usunięcie tylko u właściciela).
- **Przypomnienia** - gotowe wzorce: filtr do wody (co 3 mies. od wymiany), ekspres do kawy (co miesiąc od czyszczenia), ubezpieczenie (co rok, 30 dni wcześniej), urodziny (co rok, tydzień wcześniej i w dniu). „Zrobione” liczy kolejny termin od dnia wykonania (filtr, ekspres) albo trzyma stały dzień (polisa, urodziny).
- **Kalendarz** - miesiąc od poniedziałku, kropki przy dniach z wydarzeniem lub przypomnieniem, agenda wybranego dnia.
- **Wiadomości** - do jednego profilu albo do wszystkich, z gotowymi frazami (np. „Hej, wychodzę po pracy z koleżanką na kawę, wrócę później”).

**Ograniczenia powiadomień:** przypomnienia to powiadomienia lokalne planowane na telefonie (9:00, z wyprzedzeniem i w dniu terminu), więc działają bez internetu, ale każdy telefon planuje je sam. Wiadomości dochodzą na dwa sposoby: przez odpytywanie co 30 s, gdy aplikacja jest otwarta, oraz jako **push z FCM**, gdy jest zamknięta. Push trafia tylko na telefon domownika, do którego wiadomość jest adresowana (urządzenie zna profil, na który jest zalogowane). Na Androidzie wymaga `android/app/google-services.json` i sekretu `FCM_SERVICE_ACCOUNT` na serwerze (patrz `backend/README.md`); bez nich aplikacja działa jak dotąd. Na iOS dodatkowo potrzebne są `GoogleService-Info.plist`, klucz APNs w Firebase i konto Apple Developer, więc tam push jeszcze nie działa.

## Shelly i kolejne marki

Ekran Dom, pokoje i ustawienia nie znają marek, tylko wspólny interfejs `DeviceSource` (`lib/devices/smart_device.dart`): światła (`SmartLight`), rolety (`SmartCover`), odpytywanie i ekran dodawania. Nowa marka to nowa klasa źródła i jej wpis w `sources` w `main.dart`. Mobilus i Tuya działają jak dotąd, własnym kodem; przeniesienie ich na ten interfejs zostaje na później.

**Shelly** (`lib/shelly/`): lokalne API HTTP bez chmury, Gen1 (`/relay`, `/roller`) i Gen2+ (`/rpc/...`). Dodajesz urządzenie po adresie IP w Ustawieniach › Shelly; aplikacja rozpoznaje kanały (przekaźniki, światła, rolety). Identyfikatorem jest adres MAC, więc po zmianie IP wystarczy dodać urządzenie ponownie i pokoje zostają.

Ograniczenia: urządzenia z włączonym hasłem nie są obsługiwane (aplikacja o tym informuje); sterowanie działa tylko w sieci domowej; roleta bez kalibracji ma tylko góra/stop/dół. Odpowiedzi w testach pochodzą z dokumentacji Shelly, nie z prawdziwego urządzenia.

**Philips Hue** (`lib/hue/`): lokalne API Hue v2 (CLIP) przez mostek, tylko światła. Ustawienia › Philips Hue: „Znajdź mostek” (usługa wykrywania Philips, wymaga internetu) albo adres ręcznie, naciśnięcie okrągłego przycisku na mostku i „Połącz”. Klucz aplikacji trafia do Keychain/Keystore. Jasność regulujesz po przytrzymaniu światła na ekranie Dom. Mostek ma własny certyfikat, więc klient akceptuje go wyłącznie dla adresu tego mostka. Obsługiwany jest jeden mostek; sceny, pokoje i kolory Hue nie są obsługiwane. Odpowiedzi w testach pochodzą z opisu API, nie z prawdziwego mostka.

**Somfy TaHoma** (`lib/somfy/`): lokalne API skrzynki w trybie dewelopera (HTTPS, port 8443, token Bearer), tylko rolety, markizy i bramy. Przygotowanie: w aplikacji TaHoma „Skonfiguruj instalację” › „Dostęp do parametrów”, siedem razy dotknij numeru PIN, a w menu „Tryb dewelopera” utwórz token (pokazuje się raz). W Ustawieniach › Somfy TaHoma podaj PIN (`2001-1234-5678`) lub adres IP skrzynki i token; token trafia do Keychain/Keystore. Skrzynka prosi o rzadkie odpytywanie, więc stan odświeża się co 8 s. Pozycja i suwak działają, gdy urządzenie ma polecenie `setClosure`; silniki RTS mają tylko góra/stop/dół (stop to polecenie `my`). Nie ma wykrywania przez mDNS (wpisujesz PIN lub IP), a nazwa `gateway-PIN.local` nie zawsze rozwiązuje się na Androidzie, wtedy użyj adresu IP. Pierwsza kwadratowa TaHoma i Connectivity Kit nie są obsługiwane. Odpowiedzi w testach pochodzą ze specyfikacji API, nie z prawdziwej skrzynki.

## Klimat: czujniki i pogoda

Zakładka **Klimat** na ekranie Dom (pojawia się, gdy są czujniki albo wybrana pogoda; aktywna zakładka ma ikonę i napis, pozostałe same ikony).

- **Czujniki temperatury i wilgotności Tuya**: import z chmury (Ustawienia › Światła Tuya › import) rozpoznaje czujniki po kodach `va_temperature`/`temp_current` i `va_humidity`/`humidity_value` oraz skali z opisu urządzenia, a także baterię (`battery_percentage`). Odczyt tylko przez chmurę Tuya co 5 minut, bo czujniki na baterię śpią i nie przyjmują połączeń lokalnych. Czujniki przypisujesz do pokoi jak światła. Niski poziom baterii (≤20%) i wilgotność poza przedziałem 30-60% są wyróżnione, a kolor temperatury mówi, czy jest chłodno, komfortowo czy ciepło.
- **Ustawienia czujnika**: dotknięcie kafelka otwiera szczegóły, a administrator może zmienić ustawienia zapisywane w urządzeniu przez chmurę: jednostkę (°C/°F), progi alarmów temperatury i wilgotności, czułość oraz częstotliwość raportów. Aplikacja pokazuje tylko te, które urządzenie podaje jako zapisywalne w opisie (`functions`); czujnik trzeba raz ponownie zaimportować („Odśwież urządzenia z chmury”). Czujnik na baterii przyjmuje zmianę dopiero po przebudzeniu.
- **Pogoda**: Ustawienia › Pogoda albo karta na zakładce Klimat. Wybierasz miejscowość (wyszukiwarka Open-Meteo, polskie nazwy), a aplikacja pokazuje temperaturę, odczuwalną, wiatr, wilgotność, szansę opadów i prognozę na trzy kolejne dni. Odświeżanie co 30 minut przy otwartej aplikacji; ostatnia prognoza zostaje widoczna bez internetu. Na górze ekranu Dom jest znaczek „Na zewnątrz …”.

Źródło pogody: [Open-Meteo.com](https://open-meteo.com) (prognozy z modeli numerycznych służb meteorologicznych, bez klucza API; CC BY 4.0, atrybucja jest na karcie). **Bezpłatne tylko do użytku niekomercyjnego**: jeśli aplikacja będzie sprzedawana lub oferowana w subskrypcji, potrzebny jest płatny plan Open-Meteo z kluczem. Alternatywą dla Polski są pomiary stacji IMGW (dane publiczne), ale tylko dla ok. 60 stacji synoptycznych i bez prognozy.

Odczyty i odpowiedzi w testach pochodzą z dokumentacji (Tuya, Open-Meteo), nie z prawdziwych urządzeń i zapytań.

## Telefon i tablet

- **Telefon** (krótszy bok poniżej 600 dp) jest zablokowany w pionie; **tablet** obraca się swobodnie. Reguła działa w aplikacji (`OrientationPolicy`), więc nie trzeba osobnych ustawień w manifestach.
- **Szeroki ekran** (od 840 dp): zamiast dolnego paska jest panel nawigacji z boku, a pokoje, listy zakupów i sekcje przypomnień układają się w 2-3 kolumny; w Planerze kalendarz i plan dnia stoją obok siebie. Pozostałe ekrany (ustawienia, formularze, logowanie) mają treść wyśrodkowaną w kolumnie do 640 dp, arkusze od dołu do 640 dp.
- Podsumowanie na górze ekranu Dom to jeden wiersz znaczków z ikoną i krótką wartością (np. 1/3 świateł, 2/5 rolet otwartych, temperatura na zewnątrz i w domu); pełny opis jest w podpowiedzi po przytrzymaniu.

## Piec Viessmann (ViCare)

- Zakładka **Ogrzewanie** na ekranie Dom (dla profili z uprawnieniem „sterowanie
  ogrzewaniem”): ciepła woda (temperatura, nastawa, tryb), kocioł (zasilanie,
  palnik, program), zużycie gazu i ciepła, komunikaty statusowe pieca.
- Sterowanie: nastawa c.w.u., tryb c.w.u. (komfort / eko / wyłączona) i tryb
  ogrzewania (ogrzewanie / czuwanie). Zakresy i dozwolone wartości pochodzą z
  odpowiedzi pieca, a wyłączenie c.w.u. i czuwanie wymagają potwierdzenia.
- Oficjalne API Viessmanna, tylko przez chmurę (piec nie ma połączenia
  lokalnego). Logowanie OAuth2 + PKCE w przeglądarce, token odświeżający w
  Keychain / Keystore. Konfiguracja: Ustawienia → Piec Viessmann; potrzebny
  własny Client ID z portalu deweloperskiego, a w kliencie adres przekierowania
  `nestiq://viessmann`.
- Limit API to 1450 zapytań na dobę dla konta: odczyt co 5 minut tylko przy
  otwartej zakładce, z licznikiem zużycia w apce.
- **Usterki:** blokada awaryjna, usterki z kodem i komunikaty serwisowe pieca
  mają osobny ekran (co się stało, kiedy, co zrobić, kopiowanie kodu), dostępny
  z karty „Usterki” i z banera na zakładce Ogrzewanie.
- **Powiadomienia o usterkach** (Ustawienia → Piec Viessmann): lokalne
  powiadomienie o każdej nowej usterce, raz; dotknięcie otwiera ekran usterek.
  Pierwszy odczyt po włączeniu jest tylko punktem odniesienia (stare wpisy nie
  zasypują powiadomieniami). Przy zamkniętej aplikacji: Android sprawdza piec co
  ok. 30 minut (WorkManager), iOS tylko przez Background Fetch, czyli w terminach
  wybranych przez system.
- `tool/viessmann/probe.py` pokazuje, co API zwraca dla Twojego pieca.

## Światła Tuya

- Sterowanie w sieci lokalnej (TCP :6668, protokół 3.3 / 3.4 / 3.5, wersja
  wykrywa się sama) z trwałym połączeniem i zmianami stanu na żywo, także
  z fizycznego przycisku. Poza domem, albo gdy urządzenie nie odpowiada
  lokalnie, sterowanie przez chmurę Tuya. Tryb: automatycznie / tylko lokalnie
  / tylko chmura (Ustawienia → Światła Tuya).
- Parowanie nowego włącznika odbywa się w aplikacji Tuya (albo Smart Life). NestIQ
  importuje urządzenia i ich klucze lokalne z chmury Tuya (potrzebny własny
  projekt na iot.tuya.com; instrukcja jest w aplikacji), a adresy IP znajduje
  skanem sieci albo przyjmuje ręcznie.
- Dane chmury i klucze lokalne zostają w Keychain / Keystore na telefonie.
- Protokół jest sprawdzony względem biblioteki tinytuya (`tool/tuya/`):
  ramki, klucz sesji i podpisy chmury zgadzają się bajt w bajt, a klient
  działa na żywo z atrapą urządzenia zbudowaną na tinytuya. Z prawdziwym
  włącznikiem nie był jeszcze uruchamiany.

## Uruchomienie

```bash
flutter pub get
flutter run
```

Telefon musi być w tej samej sieci Wi‑Fi co bramka. Użytkownika i urządzenia
dodajesz w panelu WWW bramki lub w aplikacji Mobilus. Warto przypisać bramce
stały adres IP w routerze.

## Struktura

```
lib/
  main.dart                    motyw i przełączanie ekranów
  mobilus/
    proto.dart                 wiadomości protobuf (ręczny enkoder/dekoder)
    codec.dart                 ramka, klucze, AES-256-CFB
    mobilus_client.dart        połączenie MQTT po WebSocket z bramką
    gateway_discovery.dart     wyszukiwanie bramki w sieci lokalnej
    device_info.dart           typy urządzeń i interpretacja stanu
  state/
    session_controller.dart    sesja, lista urządzeń, stany
    credentials_store.dart     bezpieczny zapis danych logowania
  state/app_settings.dart      ustawienia (motyw, potwierdzanie scen)
  state/scenes_controller.dart sceny zapisane lokalnie
  screens/                     logowanie, pasek nawigacji, dom, sceny,
                               użytkownik, ustawienia
  widgets/device_card.dart     karta z przyciskami sterowania
test/
  mobilus_codec_test.dart      wektory zgodności z biblioteką Pythona
  integration/                 test na żywo z bramką lub atrapą
tool/fake_gateway/             atrapa bramki do testów bez sprzętu
docs/protocol.md               opis protokołu
backend/                       serwer kont i profili (Worker + D1)
```

W `lib/` dochodzą: `account/` (klient serwera, kontroler konta, modele
profili i uprawnień), `state/rooms_controller.dart`, ekrany logowania, wyboru
profilu, PIN-u i zarządzania profilami oraz `widgets/motion.dart` (czasy
i krzywe animacji).

## Testy

```bash
flutter test test/mobilus_codec_test.dart
```

Test na żywo z prawdziwą bramką (komendę STOP wysyła tylko z `GW_SEND_COMMAND`):

```bash
flutter test test/integration \
  --dart-define=GW_HOST=192.168.1.20 \
  --dart-define=GW_LOGIN=admin \
  --dart-define=GW_PASSWORD=haslo \
  --dart-define=GW_SEND_COMMAND=true
```

### Atrapa bramki (bez sprzętu)

```bash
python3 -m venv .venv && .venv/bin/pip install amqtt paho-mqtt cryptography protobuf
git clone https://github.com/zpieslak/mobilus-client.git /tmp/mobilus-client
.venv/bin/amqtt -c tool/fake_gateway/broker.yaml &
.venv/bin/python tool/fake_gateway/fake_gateway.py /tmp/mobilus-client &
flutter test test/integration --dart-define=GW_HOST=127.0.0.1 --dart-define=GW_PASSWORD=secret
```

Login atrapy: `admin` / `secret`. Atrapa nasłuchuje na 127.0.0.1 – żeby
połączyć się z telefonu lub emulatora, zmień `bind` w `broker.yaml` na
`0.0.0.0:8884` (w emulatorze Androida adres komputera to `10.0.2.2`).

### Podgląd ruchu bramki

Narzędzie tylko nasłuchuje (niczego nie steruje) i wypisuje wszystkie
wiadomości z bramki wraz z odszyfrowaną treścią – do poznania wiadomości,
których jeszcze nie obsługujemy, np. scen:

```bash
dart run tool/sniff_gateway.dart <IP bramki> <użytkownik> <hasło> [plik.log]
```

Po komunikacie „Zalogowano” wykonaj czynność w aplikacji Mobilus (np. otwórz
sceny). Ctrl+C kończy. Skrót hasła i klucze sesji są w dzienniku ukryte.

## Źródła

Protokół na podstawie projektu
[zpieslak/mobilus-client](https://github.com/zpieslak/mobilus-client) (MIT)
i integracji
[mobilus-client-home-assistant](https://github.com/zpieslak/mobilus-client-home-assistant).
Projekt nie jest powiązany z firmą Mobilus.

## Budowanie przy pełnym dysku systemowym

Cache Gradle można trzymać na dysku RINGLEX SSD:

```bash
export GRADLE_USER_HOME="/Volumes/RINGLEX SSD/Projects/.nestiq-cache/gradle"
flutter build apk --debug
```
