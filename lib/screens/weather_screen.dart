import 'package:flutter/material.dart';

import '../weather/weather_client.dart';
import '../weather/weather_controller.dart';
import '../weather/weather_models.dart';

/// Wybór miejscowości, dla której pokazujemy pogodę.
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key, required this.weather});

  final WeatherController weather;

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  final _query = TextEditingController();
  List<WeatherPlace> _results = const [];
  bool _busy = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final found = await widget.weather.client.search(_query.text);
      if (mounted) {
        setState(() {
          _results = found;
          _searched = true;
        });
      }
    } on WeatherException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(WeatherPlace place) async {
    await widget.weather.setPlace(place);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Pogoda')),
      body: ListenableBuilder(
        listenable: widget.weather,
        builder: (context, _) {
          final current = widget.weather.place;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (current != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(current.label),
                    subtitle: const Text('Aktualna miejscowość'),
                    trailing: IconButton(
                      tooltip: 'Usuń pogodę',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: widget.weather.clear,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                  current == null ? 'Wybierz miejscowość' : 'Zmień miejscowość',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Nazwa miejscowości',
                  hintText: 'np. Kraków',
                  suffixIcon: IconButton(
                    tooltip: 'Szukaj',
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search),
                    onPressed: _busy ? null : _search,
                  ),
                ),
                onSubmitted: (_) => _busy ? null : _search(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error)),
                ),
              if (_searched && _results.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Nie znaleziono takiej miejscowości.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              for (final r in _results)
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(r.name),
                  subtitle: Text([
                    if (r.region != null) r.region!,
                    if (r.country != null) r.country!
                  ].join(', ')),
                  onTap: () => _pick(r),
                ),
              const SizedBox(height: 16),
              Text(
                'Dane pogodowe: Open-Meteo.com (CC BY 4.0). Prognoza z modeli numerycznych, bez klucza API.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }
}
