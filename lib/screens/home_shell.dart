import 'dart:async';

import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../devices/smart_device.dart';
import '../household/household_controller.dart';
import '../weather/weather_controller.dart';
import '../state/app_settings.dart';
import '../state/rooms_controller.dart';
import '../state/scenes_controller.dart';
import '../state/session_controller.dart';
import '../tuya/tuya_controller.dart';
import '../viessmann/fault_service.dart';
import '../viessmann/viessmann_controller.dart';
import 'faults_screen.dart';
import 'home_screen.dart';
import 'planner/planner_screen.dart';
import 'scenes_screen.dart';
import 'settings_screen.dart';
import 'user_screen.dart';
import '../widgets/responsive.dart';

/// Główny ekran po wejściu w profil z dolnym paskiem nawigacji.
/// Zakładki zależą od uprawnień profilu: Sceny i Ustawienia pojawiają się
/// tylko tym, którzy mogą z nich korzystać.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.account,
    required this.controller,
    required this.scenes,
    required this.settings,
    required this.rooms,
    required this.tuya,
    required this.viessmann,
    required this.faults,
    this.household,
    this.plannerRequest,
    this.sources = const [],
    this.weather,
  });

  final AccountController account;
  final SessionController controller;
  final ScenesController scenes;
  final AppSettings settings;
  final RoomsController rooms;
  final TuyaController tuya;
  final ViessmannController viessmann;
  final FaultService faults;

  /// Planer domowy; bez niego zakładka „Planer” się nie pojawia.
  final List<DeviceSource> sources;
  final WeatherController? weather;
  final HouseholdController? household;

  /// Prośba o otwarcie planera (dotknięcie powiadomienia).
  final ValueNotifier<PlannerTab?>? plannerRequest;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _Tab {
  const _Tab(this.id, this.icon, this.selectedIcon, this.label);

  final String id;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  String _current = 'home';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.tuya.start();
    widget.weather?.start();
    for (final s in widget.sources) {
      s.start();
    }
    widget.faults.addListener(_openFaultsIfRequested);
    widget.account.addListener(_bindHousehold);
    widget.plannerRequest?.addListener(_openPlanner);
    _bindHousehold();
    widget.household?.startPolling();
    // Zimny start z powiadomienia: ekran usterek otwieramy po zbudowaniu pierwszej klatki.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openFaultsIfRequested();
      _openPlanner();
      _checkFurnace();
    });
  }

  @override
  void dispose() {
    widget.faults.removeListener(_openFaultsIfRequested);
    widget.account.removeListener(_bindHousehold);
    widget.plannerRequest?.removeListener(_openPlanner);
    widget.household?.stopPolling();
    WidgetsBinding.instance.removeObserver(this);
    widget.tuya.stop();
    widget.weather?.stop();
    for (final s in widget.sources) {
      s.stop();
    }
    super.dispose();
  }

  void _bindHousehold() => widget.household?.bind(widget.account.active?.id);

  /// Dotknięcie powiadomienia planera przełącza na zakładkę „Planer”.
  void _openPlanner() {
    if (!mounted ||
        widget.household == null ||
        widget.plannerRequest?.value == null) return;
    setState(() => _current = 'planner');
  }

  /// Dotknięcie powiadomienia o usterce otwiera ekran usterek (tylko komu wolno sterować ogrzewaniem).
  void _openFaultsIfRequested() {
    if (!mounted || !widget.faults.pendingOpen) return;
    widget.faults.consumeOpenRequest();
    if (!widget.account.permissions.controlHeating ||
        !widget.viessmann.isConfigured) return;
    Navigator.of(context).push(AppRoute(
      builder: (_) => FaultsScreen(viessmann: widget.viessmann),
    ));
  }

  /// Przy wejściu do aplikacji i powrocie z tła sprawdzamy piec, jeśli użytkownik chce powiadomień.
  void _checkFurnace() {
    if (widget.faults.enabled && widget.viessmann.isConfigured) {
      unawaited(widget.viessmann.refresh());
    }
  }

  /// Połączenia z włącznikami trzymamy tylko, gdy aplikacja jest na wierzchu.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.tuya.start();
      widget.weather?.start();
      for (final s in widget.sources) {
        s.start();
      }
      widget.household?.startPolling();
      widget.household?.refreshAll();
      _checkFurnace();
    } else if (state == AppLifecycleState.paused) {
      widget.tuya.stop();
      widget.weather?.stop();
      for (final s in widget.sources) {
        s.stop();
      }
      widget.household?.stopPolling();
    }
  }

  List<_Tab> get _tabs {
    final p = widget.account.permissions;
    return [
      const _Tab('home', Icons.home_outlined, Icons.home, 'Dom'),
      if (widget.household != null)
        const _Tab(
            'planner', Icons.checklist_outlined, Icons.checklist, 'Planer'),
      if (p.runScenes || p.editScenes)
        const _Tab(
            'scenes', Icons.auto_awesome_outlined, Icons.auto_awesome, 'Sceny'),
      const _Tab('profile', Icons.person_outline, Icons.person, 'Profil'),
      if (p.manageSettings)
        const _Tab(
            'settings', Icons.settings_outlined, Icons.settings, 'Ustawienia'),
    ];
  }

  Widget _page(String id) {
    switch (id) {
      case 'scenes':
        return ListenableBuilder(
          listenable: Listenable.merge(
              [widget.controller, widget.scenes, widget.settings]),
          builder: (_, __) => ScenesScreen(
            account: widget.account,
            controller: widget.controller,
            scenes: widget.scenes,
            settings: widget.settings,
          ),
        );
      case 'planner':
        return SafeArea(
          child: PlannerScreen(
            household: widget.household!,
            account: widget.account,
            tabRequest: widget.plannerRequest,
          ),
        );
      case 'profile':
        return UserScreen(
          account: widget.account,
          session: widget.controller,
          rooms: widget.rooms,
        );
      case 'settings':
        return SettingsScreen(
          settings: widget.settings,
          account: widget.account,
          session: widget.controller,
          rooms: widget.rooms,
          tuya: widget.tuya,
          viessmann: widget.viessmann,
          faults: widget.faults,
          sources: widget.sources,
          weather: widget.weather,
        );
      default:
        return HomeScreen(
          account: widget.account,
          session: widget.controller,
          rooms: widget.rooms,
          tuya: widget.tuya,
          viessmann: widget.viessmann,
          faults: widget.faults,
          sources: widget.sources,
          weather: widget.weather,
        );
    }
  }

  Widget _badged(_Tab tab, Widget icon) {
    final h = widget.household;
    if (tab.id != 'planner' || h == null) return icon;
    return ListenableBuilder(
      listenable: h,
      builder: (_, __) => Badge(
          isLabelVisible: h.unread > 0,
          label: Text('${h.unread}'),
          child: icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.account,
      builder: (context, _) {
        final tabs = _tabs;
        // Po zmianie profilu bieżąca zakładka mogła zniknąć.
        final index =
            tabs.indexWhere((t) => t.id == _current).clamp(0, tabs.length - 1);
        final pages = IndexedStack(
          index: index,
          children: [for (final t in tabs) _page(t.id)],
        );
        void select(int i) => setState(() => _current = tabs[i].id);
        // Szeroki ekran (tablet): panel z boku zamiast dolnego paska, treść zajmuje resztę.
        if (isWide(context)) {
          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  right: false,
                  child: NavigationRail(
                    selectedIndex: index,
                    onDestinationSelected: select,
                    labelType: NavigationRailLabelType.all,
                    destinations: [
                      for (final t in tabs)
                        NavigationRailDestination(
                          icon: _badged(t, Icon(t.icon)),
                          selectedIcon: _badged(t, Icon(t.selectedIcon)),
                          label: Text(t.label),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: pages),
              ],
            ),
          );
        }
        return Scaffold(
          body: pages,
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: select,
            destinations: [
              for (final t in tabs)
                NavigationDestination(
                  icon: _badged(t, Icon(t.icon)),
                  selectedIcon: _badged(t, Icon(t.selectedIcon)),
                  label: t.label,
                ),
            ],
          ),
        );
      },
    );
  }
}
