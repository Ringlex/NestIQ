import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nestiq/account/account_controller.dart';
import 'package:nestiq/account/account_models.dart';
import 'package:nestiq/account/nestiq_api.dart';
import 'package:nestiq/screens/home_screen.dart';
import 'package:nestiq/screens/weather_screen.dart';
import 'package:nestiq/state/rooms_controller.dart';
import 'package:nestiq/state/session_controller.dart';
import 'package:nestiq/tuya/tuya_controller.dart';
import 'package:nestiq/viessmann/viessmann_controller.dart';
import 'package:nestiq/weather/weather_client.dart';
import 'package:nestiq/weather/weather_controller.dart';
import 'package:nestiq/weather/weather_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/fake_server.dart';
import '../viessmann/fakes_faults.dart';

// Odpowiedzi zapisane według opisu API Open-Meteo, nie z prawdziwego zapytania.
Map<String, dynamic> forecastJson({num temp = 8.4, int code = 61}) => {
      'latitude': 50.06,
      'longitude': 19.94,
      'timezone': 'Europe/Warsaw',
      'current': {
        'time': '2026-10-28T12:00',
        'interval': 900,
        'temperature_2m': temp,
        'relative_humidity_2m': 81,
        'apparent_temperature': 5.9,
        'weather_code': code,
        'wind_speed_10m': 14.4,
        'is_day': 1,
      },
      'daily': {
        'time': ['2026-10-28', '2026-10-29', '2026-10-30', '2026-10-31'],
        'weather_code': [61, 3, 0, 71],
        'temperature_2m_max': [9.1, 10.5, 12.0, 2.3],
        'temperature_2m_min': [4.0, 5.2, 3.1, -1.4],
        'precipitation_probability_max': [80, 20, 0, 60],
      },
    };

const krakow = WeatherPlace(
    name: 'Kraków',
    latitude: 50.06,
    longitude: 19.94,
    region: 'Małopolskie',
    country: 'Polska');

class FakeMeteo {
  final List<Uri> requests = [];
  bool offline = false;
  int? failWith;
  Map<String, dynamic> forecast = forecastJson();
  Object geocoding = {
    'results': [
      {
        'id': 1,
        'name': 'Kraków',
        'latitude': 50.06,
        'longitude': 19.94,
        'country': 'Polska',
        'admin1': 'Małopolskie'
      },
      {
        'id': 2,
        'name': 'Kraków',
        'latitude': 51.1,
        'longitude': 17.0,
        'country': 'Polska'
      },
      {'id': 3, 'name': 'Zepsuty'},
    ],
  };

  late final MockClient client = MockClient((request) async {
    requests.add(request.url);
    if (offline) throw http.ClientException('offline');
    if (failWith != null) return http.Response('{"error":true}', failWith!);
    if (request.url.host == 'geocoding-api.open-meteo.com') {
      return http.Response(jsonEncode(geocoding), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response(jsonEncode(forecast), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
}

void main() {
  late FakeMeteo meteo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    meteo = FakeMeteo();
  });

  group('klient pogody', () {
    test('wyszukiwanie: polskie nazwy, pomija wpisy bez współrzędnych',
        () async {
      final places = await WeatherClient(client: meteo.client).search('Kraków');

      expect(places.map((p) => p.label),
          ['Kraków, Małopolskie, Polska', 'Kraków, Polska']);
      final uri = meteo.requests.single;
      expect(uri.queryParameters['language'], 'pl');
      expect(uri.queryParameters['name'], 'Kraków');
    });

    test('brak wyników (bez pola results) i za krótka fraza dają pustą listę',
        () async {
      meteo.geocoding = <String, dynamic>{'generationtime_ms': 0.3};
      expect(
          await WeatherClient(client: meteo.client).search('Xyzxyz'), isEmpty);
      expect(await WeatherClient(client: meteo.client).search('a'), isEmpty);
      expect(meteo.requests.length, 1,
          reason: 'jednoliterowej frazy nie wysyłamy');
    });

    test('prognoza: teraz i dni, z poprawnymi parametrami zapytania', () async {
      final f = await WeatherClient(client: meteo.client)
          .forecast(krakow, now: DateTime(2026, 10, 28, 12));

      expect(f.temperature, 8.4);
      expect(f.humidity, 81);
      expect(f.windKmh, 14.4);
      expect(f.apparentTemperature, 5.9);
      expect(f.isDay, isTrue);
      expect(f.days, hasLength(4));
      expect(f.days[1].max, 10.5);
      expect(f.days.last.min, -1.4);
      expect(f.days.first.precipitationChance, 80);
      final q = meteo.requests.single.queryParameters;
      expect(meteo.requests.single.host, 'api.open-meteo.com');
      expect(q['latitude'], '50.0600');
      expect(q['timezone'], 'auto');
      expect(q['current'], contains('temperature_2m'));
      expect(q['daily'], contains('temperature_2m_max'));
    });

    test('błędy: brak sieci, zły status i niepełna odpowiedź', () async {
      final client = WeatherClient(client: meteo.client);
      meteo.offline = true;
      await expectLater(
          client.forecast(krakow),
          throwsA(isA<WeatherException>()
              .having((e) => e.code, 'code', 'network')));
      meteo.offline = false;
      meteo.failWith = 500;
      await expectLater(
          client.forecast(krakow),
          throwsA(isA<WeatherException>()
              .having((e) => e.code, 'code', 'invalid')));
      meteo.failWith = null;
      meteo.forecast = {'current': {}, 'daily': {}};
      await expectLater(
          client.forecast(krakow),
          throwsA(isA<WeatherException>()
              .having((e) => e.code, 'code', 'invalid')));
    });

    test('kody pogody mają polskie opisy', () {
      expect(describeWeather(0), 'Bezchmurnie');
      expect(describeWeather(61), 'Lekki deszcz');
      expect(describeWeather(95), 'Burza');
      expect(describeWeather(1234), 'Pogoda nieznana');
    });
  });

  group('kontroler pogody', () {
    WeatherController build({Duration minAge = Duration.zero}) {
      final c = WeatherController(
          client: WeatherClient(client: meteo.client),
          refreshInterval: const Duration(milliseconds: 60),
          minAge: minAge);
      addTearDown(c.dispose);
      return c;
    }

    test('wybór miejscowości pobiera prognozę i zapisuje ją na telefonie',
        () async {
      final c = build();
      await c.setPlace(krakow);

      expect(c.forecast?.temperature, 8.4);
      expect(c.error, isNull);

      final again = build();
      await again.load();
      expect(again.place?.name, 'Kraków');
      expect(again.forecast?.temperature, 8.4,
          reason: 'ostatnia prognoza widoczna od razu, także bez internetu');
    });

    test('błąd odświeżenia zostawia poprzednią prognozę i podaje komunikat',
        () async {
      final c = build();
      await c.setPlace(krakow);
      meteo.offline = true;
      await c.refresh(force: true);

      expect(c.forecast?.temperature, 8.4);
      expect(c.error, contains('Brak połączenia'));
      meteo.offline = false;
      await c.refresh(force: true);
      expect(c.error, isNull);
    });

    test('świeża prognoza nie jest pobierana ponownie bez wymuszenia',
        () async {
      final c = build(minAge: const Duration(minutes: 10));
      await c.setPlace(krakow);
      final calls = meteo.requests.length;

      await c.refresh();
      expect(meteo.requests.length, calls);
      await c.refresh(force: true);
      expect(meteo.requests.length, calls + 1);
    });

    test(
        'odświeżanie cykliczne tylko między start() a stop(), usunięcie czyści zapis',
        () async {
      final c = build();
      await c.setPlace(krakow);
      Future<int> during(Duration d) async {
        final before = meteo.requests.length;
        await Future<void>.delayed(d);
        return meteo.requests.length - before;
      }

      expect(await during(const Duration(milliseconds: 150)), 0);
      c.start();
      expect(await during(const Duration(milliseconds: 200)), greaterThan(2));
      c.stop();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await during(const Duration(milliseconds: 150)), 0);

      await c.clear();
      final again = build();
      await again.load();
      expect(again.place, isNull);
    });
  });

  group('na ekranie', () {
    Future<void> pumpHome(WidgetTester tester, WeatherController weather,
        {Size size = const Size(390, 1200), double scale = 1.0}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final account = AccountController(
        api: NestIqApi(
            baseUrl: 'http://test', client: FakeServer((_) => null).client),
        store: MemoryStore(),
      )
        ..active = Profile.fromJson(profileJson('a', 'Mama'))
        ..phase = AccountPhase.active;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data:
              MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: HomeScreen(
            account: account,
            session: SessionController(),
            rooms: RoomsController(),
            tuya: TuyaController(),
            viessmann: ViessmannController(),
            faults: testFaults(),
            weather: weather,
          ),
        ),
      ));
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets(
        'Klimat z pogodą: karta, prognoza na kolejne dni i temperatura na zewnątrz w podsumowaniu',
        (tester) async {
      final weather =
          WeatherController(client: WeatherClient(client: meteo.client));
      addTearDown(weather.dispose);
      await tester.runAsync(() async {
        await weather.setPlace(krakow);
      });
      await pumpHome(tester, weather);

      expect(find.byTooltip('Na zewnątrz 8,4°C'), findsOneWidget);
      await tester.tap(find.byTooltip('Klimat'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Kraków, Małopolskie, Polska'), findsOneWidget);
      expect(find.text('8,4°C'), findsOneWidget);
      expect(find.text('Lekki deszcz'), findsOneWidget);
      expect(find.textContaining('odczuwalna 5,9°C'), findsOneWidget);
      expect(find.textContaining('wiatr 14 km/h'), findsOneWidget);
      expect(find.textContaining('Open-Meteo.com'), findsOneWidget);
      expect(find.text('↑ 9,1°C'), findsOneWidget);
      // Kolejne dni: jutro 11° / 5°, pojutrze 12° / 3°, potem 2° / -1°.
      expect(find.text('11° / 5°'), findsOneWidget);
      expect(find.text('12° / 3°'), findsOneWidget);
      expect(find.text('2° / -1°'), findsOneWidget);
    });

    testWidgets('zakładka Klimat jest od razu i zachęca do wyboru miejscowości',
        (tester) async {
      final weather =
          WeatherController(client: WeatherClient(client: meteo.client));
      addTearDown(weather.dispose);
      await pumpHome(tester, weather);
      expect(find.byTooltip('Klimat'), findsOneWidget);
      await tester.tap(find.byTooltip('Klimat'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Dodaj pogodę'), findsOneWidget);
      expect(
          find.textContaining('Nie dodano jeszcze czujników'), findsOneWidget);

      await tester.runAsync(() async {
        await weather.setPlace(krakow);
      });
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Dodaj pogodę'), findsNothing);
      expect(find.text('Kraków, Małopolskie, Polska'), findsOneWidget);
    });

    testWidgets('wybór miejscowości: szukanie, lista wyników i zapis',
        (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final weather =
          WeatherController(client: WeatherClient(client: meteo.client));
      addTearDown(weather.dispose);
      await tester
          .pumpWidget(MaterialApp(home: WeatherScreen(weather: weather)));

      await tester.enterText(find.byType(TextField), 'Kraków');
      await tester.tap(find.byTooltip('Szukaj'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();

      expect(find.text('Małopolskie, Polska'), findsOneWidget);
      await tester.tap(find.text('Małopolskie, Polska'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 400));

      expect(weather.place?.latitude, 50.06);
      expect(weather.forecast, isNotNull);
    });

    testWidgets('bez overflow na 360×640 przy skali tekstu 2.0',
        (tester) async {
      final weather =
          WeatherController(client: WeatherClient(client: meteo.client));
      addTearDown(weather.dispose);
      await tester.runAsync(() async {
        await weather.setPlace(krakow);
      });
      await pumpHome(tester, weather, size: const Size(360, 640), scale: 2.0);
      await tester.tap(find.byTooltip('Klimat'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });
}
