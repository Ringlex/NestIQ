import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'weather_models.dart';

class WeatherException implements Exception {
  const WeatherException(this.code);

  /// `network` albo `invalid`.
  final String code;

  String get message => code == 'network'
      ? 'Brak połączenia z serwisem pogodowym. Sprawdź internet i spróbuj ponownie.'
      : 'Serwis pogodowy odpowiedział nieoczekiwanie. Spróbuj za chwilę.';

  @override
  String toString() => 'WeatherException($code)';
}

/// Pogoda z Open-Meteo (open-meteo.com): prognozy z modeli krajowych służb meteorologicznych
/// (w Polsce m.in. DWD ICON i ECMWF) bez klucza API.
///
/// Licencja: dane na CC BY 4.0, bezpłatne do użytku niekomercyjnego. Przy komercyjnym
/// wykorzystaniu aplikacji potrzebny jest płatny plan z kluczem (host z prefiksem `customer-`).
class WeatherClient {
  WeatherClient(
      {http.Client? client, this.timeout = const Duration(seconds: 10)})
      : _http = client ?? http.Client();

  final http.Client _http;
  final Duration timeout;

  Future<dynamic> _get(Uri uri) async {
    http.Response response;
    try {
      response = await _http.get(uri).timeout(timeout);
    } on Exception {
      throw const WeatherException('network');
    }
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw const WeatherException('invalid');
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const WeatherException('invalid');
    }
  }

  /// Miejscowości o podanej nazwie (nazwy po polsku, polskie wyniki wyżej).
  Future<List<WeatherPlace>> search(String query) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    final json =
        await _get(Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': text,
      'count': '8',
      'language': 'pl',
      'format': 'json',
    }));
    // Przy braku wyników pole `results` może w ogóle nie występować.
    final results = json is Map ? json['results'] : null;
    if (results is! List) return const [];
    return [
      for (final r in results)
        if (r is Map &&
            r['latitude'] is num &&
            r['longitude'] is num &&
            r['name'] is String)
          WeatherPlace(
            name: r['name'] as String,
            latitude: (r['latitude'] as num).toDouble(),
            longitude: (r['longitude'] as num).toDouble(),
            region: r['admin1'] as String?,
            country: r['country'] as String?,
          ),
    ];
  }

  Future<WeatherForecast> forecast(WeatherPlace place, {DateTime? now}) async {
    final json = await _get(Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': place.latitude.toStringAsFixed(4),
      'longitude': place.longitude.toStringAsFixed(4),
      'current':
          'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'timezone': 'auto',
      'forecast_days': '4',
      'wind_speed_unit': 'kmh',
    }));
    if (json is! Map) throw const WeatherException('invalid');
    final current = json['current'];
    final daily = json['daily'];
    if (current is! Map ||
        daily is! Map ||
        current['temperature_2m'] is! num ||
        current['weather_code'] is! num) {
      throw const WeatherException('invalid');
    }
    final times = (daily['time'] as List?) ?? const [];
    List list(String key) => (daily[key] as List?) ?? const [];
    final codes = list('weather_code');
    final max = list('temperature_2m_max');
    final min = list('temperature_2m_min');
    final rain = list('precipitation_probability_max');
    final days = <DayForecast>[];
    for (var i = 0; i < times.length; i++) {
      if (i >= codes.length ||
          i >= max.length ||
          i >= min.length ||
          codes[i] is! num ||
          max[i] is! num ||
          min[i] is! num) continue;
      days.add(DayForecast(
        date: DateTime.parse(times[i] as String),
        code: (codes[i] as num).toInt(),
        min: (min[i] as num).toDouble(),
        max: (max[i] as num).toDouble(),
        precipitationChance:
            i < rain.length && rain[i] is num ? (rain[i] as num).toInt() : null,
      ));
    }
    return WeatherForecast(
      temperature: (current['temperature_2m'] as num).toDouble(),
      apparentTemperature:
          (current['apparent_temperature'] as num?)?.toDouble(),
      humidity: (current['relative_humidity_2m'] as num?)?.toDouble(),
      windKmh: (current['wind_speed_10m'] as num?)?.toDouble(),
      code: (current['weather_code'] as num).toInt(),
      isDay: current['is_day'] != 0,
      days: days,
      fetchedAt: now ?? DateTime.now(),
    );
  }
}
