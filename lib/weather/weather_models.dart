/// Miejscowość, dla której pokazujemy pogodę.
class WeatherPlace {
  const WeatherPlace(
      {required this.name,
      required this.latitude,
      required this.longitude,
      this.region,
      this.country});

  factory WeatherPlace.fromJson(Map<String, dynamic> json) => WeatherPlace(
        name: json['name'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        region: json['region'] as String?,
        country: json['country'] as String?,
      );

  final String name;
  final double latitude;
  final double longitude;

  /// Województwo / region, np. „Mazowieckie”.
  final String? region;
  final String? country;

  /// „Kraków, Małopolskie, Polska”.
  String get label => [
        name,
        if (region != null && region != name) region!,
        if (country != null) country!
      ].join(', ');

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'region': region,
        'country': country,
      };
}

class DayForecast {
  const DayForecast(
      {required this.date,
      required this.code,
      required this.min,
      required this.max,
      this.precipitationChance});

  factory DayForecast.fromJson(Map<String, dynamic> json) => DayForecast(
        date: DateTime.parse(json['date'] as String),
        code: (json['code'] as num).toInt(),
        min: (json['min'] as num).toDouble(),
        max: (json['max'] as num).toDouble(),
        precipitationChance: (json['precipitationChance'] as num?)?.toInt(),
      );

  final DateTime date;

  /// Kod pogody WMO.
  final int code;
  final double min;
  final double max;

  /// Prawdopodobieństwo opadu w %.
  final int? precipitationChance;

  Map<String, dynamic> toJson() => {
        'date':
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'code': code,
        'min': min,
        'max': max,
        'precipitationChance': precipitationChance,
      };
}

class WeatherForecast {
  const WeatherForecast({
    required this.temperature,
    required this.apparentTemperature,
    required this.humidity,
    required this.windKmh,
    required this.code,
    required this.isDay,
    required this.days,
    required this.fetchedAt,
  });

  factory WeatherForecast.fromJson(Map<String, dynamic> json) =>
      WeatherForecast(
        temperature: (json['temperature'] as num).toDouble(),
        apparentTemperature: (json['apparentTemperature'] as num?)?.toDouble(),
        humidity: (json['humidity'] as num?)?.toDouble(),
        windKmh: (json['windKmh'] as num?)?.toDouble(),
        code: (json['code'] as num).toInt(),
        isDay: json['isDay'] != false,
        days: [
          for (final d in json['days'] as List)
            DayForecast.fromJson((d as Map).cast<String, dynamic>())
        ],
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      );

  final double temperature;
  final double? apparentTemperature;
  final double? humidity;
  final double? windKmh;

  /// Kod pogody WMO.
  final int code;
  final bool isDay;

  /// Dziś i kolejne dni.
  final List<DayForecast> days;
  final DateTime fetchedAt;

  Map<String, dynamic> toJson() => {
        'temperature': temperature,
        'apparentTemperature': apparentTemperature,
        'humidity': humidity,
        'windKmh': windKmh,
        'code': code,
        'isDay': isDay,
        'days': [for (final d in days) d.toJson()],
        'fetchedAt': fetchedAt.toIso8601String(),
      };
}

/// Opis kodu pogody WMO po polsku (tabela z dokumentacji Open-Meteo).
String describeWeather(int code) => switch (code) {
      0 => 'Bezchmurnie',
      1 => 'Przeważnie bezchmurnie',
      2 => 'Częściowe zachmurzenie',
      3 => 'Pochmurno',
      45 || 48 => 'Mgła',
      51 || 53 || 55 => 'Mżawka',
      56 || 57 => 'Marznąca mżawka',
      61 => 'Lekki deszcz',
      63 => 'Deszcz',
      65 => 'Silny deszcz',
      66 || 67 => 'Marznący deszcz',
      71 => 'Lekki śnieg',
      73 => 'Śnieg',
      75 => 'Silny śnieg',
      77 => 'Ziarna śnieżne',
      80 => 'Przelotny deszcz',
      81 => 'Przelotne opady deszczu',
      82 => 'Ulewy',
      85 || 86 => 'Przelotny śnieg',
      95 => 'Burza',
      96 || 99 => 'Burza z gradem',
      _ => 'Pogoda nieznana',
    };
