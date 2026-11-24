import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../devices/smart_device.dart';
import '../weather/weather_controller.dart';
import 'weather_screen.dart';
import '../state/app_settings.dart';
import '../state/rooms_controller.dart';
import '../state/session_controller.dart';
import '../tuya/tuya_controller.dart';
import '../viessmann/fault_service.dart';
import '../viessmann/viessmann_controller.dart';
import 'gateway_connect_screen.dart';
import 'profiles_screen.dart';
import 'rooms_screen.dart';
import 'tuya_screen.dart';
import 'viessmann_screen.dart';
import '../widgets/responsive.dart';

/// Ustawienia – dostępne tylko dla profili z prawem zmiany ustawień.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.account,
    required this.session,
    required this.rooms,
    required this.tuya,
    required this.viessmann,
    required this.faults,
    this.sources = const [],
    this.weather,
  });

  final AppSettings settings;
  final AccountController account;
  final SessionController session;
  final RoomsController rooms;
  final TuyaController tuya;
  final ViessmannController viessmann;
  final FaultService faults;
  final List<DeviceSource> sources;
  final WeatherController? weather;

  Future<void> _disconnect(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rozłączyć bramkę?'),
        content: const Text(
            'Zapisane hasło do bramki zostanie usunięte z tego telefonu.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Rozłącz')),
        ],
      ),
    );
    if (ok == true) await session.logout();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          session,
          settings,
          tuya,
          viessmann,
          ...sources,
          if (weather != null) weather!
        ]),
        builder: (context, _) {
          final connected = session.phase == SessionPhase.connected;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text('Połączenia', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.router_outlined),
                  title: const Text('Mobilus Cosmo GTW'),
                  subtitle: Text(connected
                      ? '${session.gatewayHost ?? ''} · połączono lokalnie'
                      : 'Niepołączona'),
                  trailing: connected
                      ? TextButton(
                          onPressed: () => _disconnect(context),
                          child: const Text('Rozłącz'))
                      : FilledButton.tonal(
                          onPressed: () => Navigator.of(context).push(AppRoute(
                            builder: (_) =>
                                GatewayConnectScreen(session: session),
                          )),
                          child: const Text('Połącz'),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lightbulb_outline),
                  title: const Text('Światła Tuya'),
                  subtitle: Text(tuya.hasDevices
                      ? 'Urządzeń: ${tuya.devices.length} · ${tuya.mode.label.toLowerCase()}'
                      : 'Niepodłączone'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(AppRoute(
                    builder: (_) => TuyaScreen(tuya: tuya, rooms: rooms),
                  )),
                ),
              ),
              if (weather case final w?) ...[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.wb_sunny_outlined),
                    title: const Text('Pogoda'),
                    subtitle:
                        Text(w.place?.label ?? 'Nie wybrano miejscowości'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(AppRoute(
                      builder: (_) => WeatherScreen(weather: w),
                    )),
                  ),
                ),
              ],
              for (final source in sources) ...[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.developer_board),
                    title: Text(source.title),
                    subtitle: Text(source.summary),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(AppRoute(
                      builder: source.buildSetup,
                    )),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.local_fire_department_outlined),
                  title: const Text('Piec Viessmann'),
                  subtitle: Text(viessmann.isConfigured
                      ? 'Połączono · ${viessmann.device!.modelId}'
                      : 'Niepodłączony'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(AppRoute(
                    builder: (_) =>
                        ViessmannScreen(viessmann: viessmann, faults: faults),
                  )),
                ),
              ),
              const SizedBox(height: 24),
              Text('Dom', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.group_outlined),
                      title: const Text('Profile domowników'),
                      subtitle: Text('${account.profiles.length}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(AppRoute(
                        builder: (_) =>
                            ProfilesScreen(account: account, rooms: rooms),
                      )),
                    ),
                    ListTile(
                      leading: const Icon(Icons.meeting_room_outlined),
                      title: const Text('Pokoje i grupy'),
                      subtitle: const Text('Podział świateł i rolet na pokoje'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(AppRoute(
                        builder: (_) => RoomsScreen(
                            rooms: rooms,
                            session: session,
                            tuya: tuya,
                            sources: sources),
                      )),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('Wygląd', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto),
                      label: Text('System')),
                  ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode),
                      label: Text('Jasny')),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode),
                      label: Text('Ciemny')),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (s) => settings.setThemeMode(s.first),
              ),
              const SizedBox(height: 24),
              Text('Sceny', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.help_outline),
                  title: const Text('Potwierdzaj uruchomienie'),
                  subtitle: const Text('Pytaj przed wysłaniem komend sceny'),
                  value: settings.confirmScenes,
                  onChanged: settings.setConfirmScenes,
                ),
              ),
              const SizedBox(height: 24),
              Text('Informacje', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('O aplikacji'),
                  subtitle: const Text('NestIQ 1.0.0'),
                  onTap: () => showAboutDialog(
                    context: context,
                    applicationName: 'NestIQ',
                    applicationVersion: '1.0.0',
                    applicationIcon: Icon(Icons.roofing_rounded,
                        color: theme.colorScheme.primary),
                    children: const [
                      Text(
                          'Sterowanie światłami i roletami w domu. Rolety Mobilus COSMO 2WAY '
                          'przez bramkę Cosmo GTW w sieci lokalnej.'),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
