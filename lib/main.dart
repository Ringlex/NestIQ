import 'package:flutter/material.dart';

import 'account/account_controller.dart';
import 'devices/smart_device.dart';
import 'household/household_controller.dart';
import 'hue/hue_controller.dart';
import 'household/reminder_plan.dart';
import 'notifications/planner_notifier.dart';
import 'notifications/push_service.dart';
import 'screens/planner/planner_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/profile_form_screen.dart';
import 'screens/profile_picker_screen.dart';
import 'screens/verify_email_screen.dart';
import 'shelly/shelly_controller.dart';
import 'somfy/somfy_controller.dart';
import 'state/app_settings.dart';
import 'weather/weather_controller.dart';
import 'state/rooms_controller.dart';
import 'state/scenes_controller.dart';
import 'state/session_controller.dart';
import 'tuya/tuya_controller.dart';
import 'notifications/fault_background.dart';
import 'notifications/notification_service.dart';
import 'viessmann/fault_service.dart';
import 'viessmann/viessmann_controller.dart';
import 'widgets/motion.dart';
import 'widgets/responsive.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifier = LocalFaultNotifier.instance;
  await notifier.init();
  final faults = FaultService(
    notifier: notifier,
    scheduler: WorkmanagerFaultScheduler(),
    requestPermission: notifier.requestPermission,
    taps: notifier.taps.where((payload) => payload == faultPayload),
    launchedFromNotification: notifier.launchedFromNotification,
  )..load();
  final push = await FirebasePushService.start();
  final account = AccountController(push: push)..restore();
  final planner = LocalPlannerNotifier(notifier);
  final plannerRequest = ValueNotifier<PlannerTab?>(null);
  PlannerTab? tabFor(String payload) => switch (payload) {
        messagesPayload => PlannerTab.messages,
        reminderPayload => PlannerTab.reminders,
        _ => null,
      };
  notifier.taps.listen((payload) =>
      plannerRequest.value = tabFor(payload) ?? plannerRequest.value);
  final launch = notifier.launchPayload;
  if (launch != null) plannerRequest.value = tabFor(launch);
  final household = HouseholdController(
    api: account.api,
    // Przypomnienia planujemy lokalnie na telefonie; serwer nie wysyła pushy.
    onRemindersChanged: (reminders) {
      if (reminders.isNotEmpty) notifier.requestPermission();
      planner.scheduleReminders(
          planReminderNotifications(reminders, now: DateTime.now()));
    },
    onNewMessages: (messages) {
      notifier.requestPermission();
      planner.showMessages(
          messages,
          (id) =>
              account.profiles.where((p) => p.id == id).firstOrNull?.name ??
              'Ktoś');
    },
  );
  // Push przy otwartej aplikacji system pomija, więc tylko odświeżamy wiadomości.
  push.foreground.listen((event) {
    if (event.type == 'message') household.refreshMessages();
  });
  push.opened.listen((event) {
    if (event.type == 'message') plannerRequest.value = PlannerTab.messages;
  });
  runApp(NestIQApp(
    household: household,
    plannerRequest: plannerRequest,
    weather: WeatherController()..load(),
    sources: [
      ShellyController()..load(),
      HueController()..load(),
      SomfyController()..load()
    ],
    account: account,
    rooms: RoomsController()..load(),
    tuya: TuyaController()..load(),
    // Każdy udany odczyt pieca w aplikacji sprawdza też, czy nie ma nowych usterek.
    viessmann: ViessmannController(onRefreshed: faults.handle)..load(),
    faults: faults,
    controller: SessionController()..restore(),
    scenes: ScenesController()..load(),
    settings: AppSettings()..load(),
  ));
}

class NestIQApp extends StatelessWidget {
  const NestIQApp({
    super.key,
    required this.account,
    required this.rooms,
    required this.tuya,
    required this.viessmann,
    required this.faults,
    required this.controller,
    required this.scenes,
    required this.settings,
    this.household,
    this.plannerRequest,
    this.sources = const [],
    this.weather,
  });

  final AccountController account;
  final RoomsController rooms;
  final TuyaController tuya;
  final ViessmannController viessmann;
  final FaultService faults;
  final SessionController controller;
  final ScenesController scenes;
  final AppSettings settings;
  final List<DeviceSource> sources;
  final WeatherController? weather;
  final HouseholdController? household;
  final ValueNotifier<PlannerTab?>? plannerRequest;

  static const seed = Color(0xFF1F6F78);

  ThemeData _theme(Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withOpacity(0.4),
      ),
      // Arkusze od dołu nie rozciągają się na całą szerokość tabletu.
      bottomSheetTheme: const BottomSheetThemeData(
          constraints: BoxConstraints(maxWidth: 640)),
      cardTheme: CardTheme(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'NestIQ',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: settings.themeMode,
        builder: (context, child) =>
            OrientationPolicy(child: child ?? const SizedBox.shrink()),
        home: ListenableBuilder(
          listenable: account,
          builder: (context, _) => AnimatedSwitcher(
            duration: Motion.enter,
            switchInCurve: Motion.curve,
            child: KeyedSubtree(
              key: ValueKey(account.phase),
              child: switch (account.phase) {
                AccountPhase.restoring => const _Splash(),
                AccountPhase.offline => _OfflineScreen(onRetry: account.retry),
                AccountPhase.signedOut =>
                  ContentWidth(child: AuthScreen(account: account)),
                AccountPhase.awaitingVerification =>
                  ContentWidth(child: VerifyEmailScreen(account: account)),
                AccountPhase.needsProfile => ContentWidth(
                    child: ProfileFormScreen.first(
                        account: account, rooms: rooms)),
                AccountPhase.choosingProfile =>
                  ContentWidth(child: ProfilePickerScreen(account: account)),
                AccountPhase.active => HomeShell(
                    account: account,
                    controller: controller,
                    scenes: scenes,
                    settings: settings,
                    rooms: rooms,
                    tuya: tuya,
                    viessmann: viessmann,
                    faults: faults,
                    household: household,
                    plannerRequest: plannerRequest,
                    sources: sources,
                    weather: weather,
                  ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    // Te same kolory i logo co ekran startowy systemu, żeby przejście było płynne.
    return Scaffold(
      backgroundColor: NestIQApp.seed,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/brand/logo.png', width: 120, height: 120),
            const SizedBox(height: 24),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// Serwer kont jest nieosiągalny, a na telefonie czeka zapisana sesja.
class _OfflineScreen extends StatelessWidget {
  const _OfflineScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 56, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text('Brak połączenia z serwerem',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Do wejścia w profil potrzebny jest internet. Sprawdź połączenie i spróbuj ponownie.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                child: const Text('Spróbuj ponownie'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
