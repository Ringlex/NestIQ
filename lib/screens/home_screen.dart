import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_controller.dart';
import '../account/account_models.dart';
import '../devices/smart_device.dart';
import '../mobilus/device_info.dart';
import '../mobilus/proto.dart';
import '../state/rooms_controller.dart';
import '../state/session_controller.dart';
import '../tuya/tuya_controller.dart';
import '../viessmann/fault_service.dart';
import '../viessmann/viessmann_controller.dart';
import '../tuya/tuya_models.dart';
import '../widgets/cover_tile.dart';
import '../widgets/device_tile.dart';
import '../widgets/home_summary.dart';
import '../widgets/sensor_sheet.dart';
import '../widgets/sensor_tile.dart';
import '../widgets/weather_card.dart';
import '../weather/weather_controller.dart';
import 'weather_screen.dart';
import '../widgets/motion.dart';
import 'gateway_connect_screen.dart';
import 'heating_view.dart';
import 'tuya_screen.dart';
import 'viessmann_screen.dart';
import '../widgets/responsive.dart';

/// Ekran Dom: zakładki Oświetlenie / Rolety, urządzenia pogrupowane w pokoje.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.account,
    required this.session,
    required this.rooms,
    required this.tuya,
    required this.viessmann,
    required this.faults,
    this.sources = const [],
    this.weather,
  });

  final AccountController account;
  final SessionController session;
  final RoomsController rooms;
  final TuyaController tuya;
  final ViessmannController viessmann;
  final FaultService faults;

  /// Dodatkowe marki (Shelly itd.); ekran zna tylko ich wspólny interfejs.
  final List<DeviceSource> sources;

  /// Pogoda dla wybranej miejscowości; bez niej nie ma karty pogody.
  final WeatherController? weather;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int _direction = 1;
  final Map<String, bool> _open = {};

  static const _tipKey = 'home_tip_seen';

  /// Wskazówka o gestach pokazuje się raz; do czasu odczytu uznajemy ją za widzianą.
  bool _tipSeen = true;

  @override
  void initState() {
    super.initState();
    _loadTip();
  }

  Future<void> _loadTip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || (prefs.getBool(_tipKey) ?? false)) return;
      setState(() => _tipSeen = false);
    } catch (_) {
      // Bez pamięci ustawień wskazówki po prostu nie pokazujemy.
    }
  }

  Future<void> _dismissTip() async {
    setState(() => _tipSeen = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_tipKey, true);
    } catch (_) {}
  }

  static const _unassigned = '_unassigned';

  /// Ogrzewanie widzą tylko profile z prawem sterowania nim.
  bool get _hasHeatingTab => widget.account.permissions.controlHeating;

  /// Klimat pojawia się, gdy profil ma dostęp do jakiegoś czujnika.
  bool get _hasClimateTab =>
      _visibleSensors().isNotEmpty || widget.weather != null;

  /// Identyfikatory widocznych zakładek w kolejności wyświetlania.
  List<String> get _tabIds => [
        'lights',
        'blinds',
        if (_hasClimateTab) 'climate',
        if (_hasHeatingTab) 'heating',
      ];

  int get _tabCount => _tabIds.length;

  /// Po zmianie profilu albo zniknięciu czujników zakładka mogła zniknąć.
  int get _currentTab => _tab.clamp(0, _tabCount - 1);

  String get _currentId => _tabIds[_currentTab];

  void _openTab(String id) {
    final index = _tabIds.indexOf(id);
    if (index >= 0) _setTab(index);
  }

  void _setTab(int tab) => setState(() {
        _direction = tab > _currentTab ? 1 : -1;
        _tab = tab;
      });

  String get _greeting {
    final hour = DateTime.now().hour;
    final hello =
        hour < 11 ? 'Dzień dobry' : (hour < 18 ? 'Cześć' : 'Dobry wieczór');
    return '$hello, ${widget.account.active?.name ?? ''}';
  }

  List<_Cover> _blinds() => [
        for (final d in widget.session.devices)
          if (MobilusDeviceType.fromCode(d.type) case final type
              when type.isCover || type.isGarage)
            _Cover.mobilus(d),
        for (final source in widget.sources)
          for (final c in source.covers) _Cover.smart(c),
      ];

  /// Czujniki z Tuya (odczyt przez chmurę) i innych marek.
  List<SmartSensor> _allSensors() {
    final tuya = widget.tuya;
    return [
      for (final d in tuya.sensorDevices)
        if (tuya.readingOf(d.id) case final r?)
          SmartSensor(
            key: RoomsController.tuyaSensorKey(d.id),
            name: d.name,
            available: true,
            temperature: r.temperature,
            humidity: r.humidity,
            battery: r.battery,
            updatedAt: r.updatedAt,
            settings: tuya.settingsOf(d),
          )
        else
          SmartSensor(
              key: RoomsController.tuyaSensorKey(d.id),
              name: d.name,
              available: false,
              settings: tuya.settingsOf(d)),
      for (final source in widget.sources) ...source.sensors,
    ];
  }

  List<({String id, String title, List<SmartSensor> items})> _sensorGroups() =>
      _group(_allSensors(), (s) => s.key);

  Iterable<SmartSensor> _visibleSensors() =>
      _sensorGroups().expand((g) => g.items);

  /// Światła ze wszystkich źródeł: przełączniki Mobilus i przyciski włączników Tuya.
  List<SmartLight> _allLights() {
    final session = widget.session;
    final tuya = widget.tuya;
    return [
      for (final d in session.devices)
        if (MobilusDeviceType.fromCode(d.type).isSwitch)
          SmartLight(
            key: RoomsController.mobilusKey(d.id),
            name: d.name.isEmpty ? 'Urządzenie ${d.id}' : d.name,
            on: session.statuses[d.id]?.isOn,
            status: session.statuses[d.id]?.label ?? 'stan nieznany',
            available: true,
            set: (value) async => session.send(d, value ? 'ON' : 'OFF'),
          ),
      for (final l in tuya.lights) _tuyaLight(l),
      for (final source in widget.sources) ...source.lights,
    ];
  }

  SmartLight _tuyaLight(TuyaLight light) {
    final tuya = widget.tuya;
    final route = tuya.routeOf(light.device.id);
    final on = tuya.isOn(light.device.id, light.channel.dpId);
    final available = route == TuyaRoute.local || route == TuyaRoute.cloud;
    final state =
        on == null ? 'stan nieznany' : (on ? 'Włączone' : 'Wyłączone');
    return SmartLight(
      key: RoomsController.tuyaKey(light.device.id, light.channel.dpId),
      name: light.device.channelLabel(light.channel),
      on: on,
      status: switch (route) {
        TuyaRoute.local => '$state · lokalnie',
        TuyaRoute.cloud => '$state · chmura',
        TuyaRoute.connecting => 'Łączenie…',
        TuyaRoute.offline => 'Niedostępne',
      },
      icon: switch (route) {
        TuyaRoute.local => Icons.wifi,
        TuyaRoute.cloud => Icons.cloud_outlined,
        TuyaRoute.connecting => Icons.sync,
        TuyaRoute.offline => Icons.cloud_off_outlined,
      },
      available: available,
      set: (value) => tuya.setChannel(light.device, light.channel, value),
    );
  }

  /// Pokoje widoczne dla profilu wraz z ich urządzeniami.
  List<({String id, String title, List<T> items})> _group<T>(
      List<T> items, String Function(T) keyOf) {
    final allowed = widget.account.active?.allowedRooms;
    final rooms = widget.rooms;
    if (rooms.rooms.isEmpty) {
      return items.isEmpty
          ? const []
          : [(id: _unassigned, title: 'Wszystkie urządzenia', items: items)];
    }
    final groups = <({String id, String title, List<T> items})>[];
    for (final room in rooms.rooms) {
      if (allowed != null && !allowed.contains(room.id)) continue;
      final inRoom =
          items.where((i) => rooms.roomOfKey(keyOf(i)) == room.id).toList();
      if (inRoom.isNotEmpty) {
        groups.add((id: room.id, title: room.name, items: inRoom));
      }
    }
    // Urządzeń bez pokoju nie pokazujemy profilom ograniczonym do wybranych pokoi.
    if (allowed == null) {
      final loose = items
          .where((i) => rooms.byId(rooms.roomOfKey(keyOf(i)) ?? '') == null)
          .toList();
      if (loose.isNotEmpty) {
        groups.add((id: _unassigned, title: 'Pozostałe', items: loose));
      }
    }
    return groups;
  }

  List<({String id, String title, List<SmartLight> items})> _lightGroups() =>
      _group(_allLights(), (l) => l.key);

  List<({String id, String title, List<_Cover> items})> _blindGroups() =>
      _group(_blinds(), (c) => c.key);

  Iterable<SmartLight> _visibleLights() =>
      _lightGroups().expand((g) => g.items);

  Iterable<_Cover> _visibleBlinds() => _blindGroups().expand((g) => g.items);

  Future<void> _setLight(SmartLight light, bool value) async {
    try {
      await light.set(value);
    } on DeviceControlException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _lightsOff() {
    final on =
        _visibleLights().where((l) => l.on == true && l.available).toList();
    if (on.isEmpty) return;
    for (final l in on) {
      _setLight(l, false);
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(on.length == 1
            ? 'Wyłączono 1 światło'
            : 'Wyłączono ${on.length} świateł'),
        duration: const Duration(milliseconds: 3600),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Cofnij',
          onPressed: () {
            for (final l in on) {
              _setLight(l, true);
            }
          },
        ),
      ));
  }

  void _allBlinds(String command) => _commandCovers(_visibleBlinds(), command);

  /// Polecenie dla wielu rolet: Mobilus jedną paczką, inne marki każda osobno.
  void _commandCovers(Iterable<_Cover> covers, String command) {
    final mobilus = {
      for (final c in covers)
        if (c.device != null) c.device!.id: command
    };
    if (mobilus.isNotEmpty) widget.session.sendAll(mobilus);
    for (final c in covers.where((c) => c.smart != null)) {
      _sendSmart(c.smart!, command);
    }
  }

  Future<void> _sendSmart(SmartCover cover, String command) async {
    try {
      await cover.command(command);
    } on DeviceControlException catch (e) {
      _showMessage(e.message);
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Wiersz rolety odpowiedni do marki.
  Widget _coverTile(_Cover c, bool canControl) {
    void onDetails() => _showBlindSheet(c.key, canControl);
    final device = c.device;
    if (device != null) {
      return DeviceTile(
        onDetails: onDetails,
        device: device,
        status: widget.session.statuses[device.id],
        enabled: canControl,
        onCommand: (value) => widget.session.send(device, value),
      );
    }
    return CoverTile(
      cover: c.smart!,
      enabled: canControl,
      onDetails: onDetails,
      onError: (e) => _showMessage(e.message),
    );
  }

  /// Przyciski zbiorcze w nagłówku pokoju; przy jednym urządzeniu są zbędne.
  Widget? _lightsBulk(List<SmartLight> items, bool canControl) {
    if (!canControl || items.length < 2) return null;
    void all(bool value) {
      for (final l in items.where((l) => l.available && l.on != value)) {
        _setLight(l, value);
      }
    }

    return _BulkRow(children: [
      _BulkButton(
          icon: Icons.lightbulb,
          label: 'Włącz w pokoju',
          onPressed: () => all(true)),
      _BulkButton(
          icon: Icons.lightbulb_outline,
          label: 'Wyłącz w pokoju',
          onPressed: () => all(false)),
    ]);
  }

  Widget? _blindsBulk(List<_Cover> items, bool canControl) {
    if (!canControl || items.length < 2) return null;
    void all(String command) => _commandCovers(items, command);
    return _BulkRow(children: [
      _BulkButton(
          icon: Icons.keyboard_arrow_up_rounded,
          label: 'W górę',
          onPressed: () => all('UP')),
      _BulkButton(
          icon: Icons.stop_rounded,
          label: 'Stop',
          onPressed: () => all('STOP')),
      _BulkButton(
          icon: Icons.keyboard_arrow_down_rounded,
          label: 'W dół',
          onPressed: () => all('DOWN')),
    ]);
  }

  /// Szczegóły światła (przytrzymanie wiersza): duży przycisk i skąd idzie sterowanie.
  void _showLightSheet(String key, bool canControl) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListenableBuilder(
        listenable:
            Listenable.merge([widget.session, widget.tuya, ...widget.sources]),
        builder: (context, _) {
          final light = _allLights().where((l) => l.key == key).firstOrNull;
          if (light == null) return const SizedBox(height: 120);
          final theme = Theme.of(context);
          final isOn = light.on ?? false;
          final (bg, fg) =
              LightTile.colors(theme.brightness, isOn, theme.colorScheme);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: Motion.toggle,
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                        color: bg, borderRadius: BorderRadius.circular(24)),
                    child: Icon(
                        isOn ? Icons.lightbulb : Icons.lightbulb_outline,
                        size: 36,
                        color: fg),
                  ),
                  const SizedBox(height: 12),
                  Text(light.name,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(light.status,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  if (light.setBrightness != null &&
                      light.brightness != null) ...[
                    const SizedBox(height: 12),
                    _BrightnessSlider(
                      value: light.brightness!,
                      enabled: canControl && light.available,
                      onChanged: (v) async {
                        try {
                          await light.setBrightness!(v);
                        } on DeviceControlException catch (e) {
                          _showMessage(e.message);
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: canControl && light.available
                        ? () => _setLight(light, !isOn)
                        : null,
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: const StadiumBorder()),
                    icon: Icon(isOn
                        ? Icons.power_settings_new
                        : Icons.lightbulb_outline),
                    label: Text(isOn ? 'Wyłącz' : 'Włącz'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Szczegóły rolety (przytrzymanie): duże sterowanie i suwak pozycji.
  void _showBlindSheet(String key, bool canControl) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ListenableBuilder(
        listenable: Listenable.merge([widget.session, ...widget.sources]),
        builder: (context, _) {
          final cover = _blinds().where((c) => c.key == key).firstOrNull;
          if (cover == null) return const SizedBox(height: 120);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SingleChildScrollView(
                child: _coverTile(cover, canControl),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _connectGateway() => Navigator.of(context).push(AppRoute(
        builder: (_) => GatewayConnectScreen(session: widget.session),
      ));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profile = widget.account.active;

    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            widget.account,
            widget.session,
            widget.rooms,
            widget.tuya,
            widget.viessmann,
            ...widget.sources,
            if (widget.weather case final w?) w,
          ]),
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Dom',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                          Text(_greeting,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    if (profile != null)
                      ActionChip(
                        avatar: ProfileAvatar(profile: profile, size: 28),
                        label: Text(profile.name),
                        tooltip: 'Zmień profil',
                        shape: const StadiumBorder(),
                        onPressed: widget.account.switchProfile,
                      ),
                  ],
                ),
              ),
              _summary(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: SlidingTabs(
                  collapseInactive: true,
                  labels: [
                    'Oświetlenie',
                    'Rolety',
                    if (_hasClimateTab) 'Klimat',
                    if (_hasHeatingTab) 'Ogrzewanie',
                  ],
                  icons: [
                    Icons.lightbulb_outline,
                    Icons.blinds,
                    if (_hasClimateTab) Icons.thermostat,
                    if (_hasHeatingTab) Icons.local_fire_department_outlined,
                  ],
                  index: _currentTab,
                  onChanged: _setTab,
                ),
              ),
              if (widget.session.connectionLost)
                MaterialBanner(
                  content: const Text('Utracono połączenie z bramką.'),
                  leading: const Icon(Icons.wifi_off),
                  actions: [
                    TextButton(
                        onPressed: widget.session.refresh,
                        child: const Text('Połącz ponownie')),
                  ],
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.tabs,
                  switchInCurve: Motion.curve,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                              begin: Offset(0.08 * _direction, 0),
                              end: Offset.zero)
                          .animate(animation),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(
                        '${_currentTab}_${widget.session.phase.name}_${widget.tuya.hasDevices}_${widget.sources.map((s) => s.hasDevices).join()}'),
                    child: _body(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary() {
    final lights = _visibleLights().toList();
    final blinds = _visibleBlinds().toList();
    final temperatures = [
      for (final s in _visibleSensors())
        if (s.temperature != null) s.temperature!
    ];
    final averageTemperature = temperatures.isEmpty
        ? null
        : temperatures.reduce((a, b) => a + b) / temperatures.length;
    return HomeSummary(
      lightsOn: lights.where((l) => l.on == true).length,
      lightsTotal: lights.length,
      blindsOpen: blinds
          .where((c) =>
              ((c.device != null
                      ? widget.session.statuses[c.device!.id]?.position
                      : c.smart!.position) ??
                  0) >
              0)
          .length,
      blindsTotal: blinds.length,
      malfunction:
          _hasHeatingTab && (widget.viessmann.state?.malfunction ?? false),
      onLights: () => _openTab('lights'),
      onBlinds: () => _openTab('blinds'),
      onHeating: _hasHeatingTab ? () => _openTab('heating') : null,
      averageTemperature: averageTemperature,
      outdoorTemperature: widget.weather?.forecast?.temperature,
      onClimate: () => _openTab('climate'),
    );
  }

  Widget _body(BuildContext context) {
    final session = widget.session;
    final lights = _currentId == 'lights';
    final canManage = widget.account.permissions.manageSettings;

    if (_currentId == 'climate') return _climateBody();

    if (_currentId == 'heating') {
      return _HeatingTab(
        viessmann: widget.viessmann,
        canControl: widget.account.permissions.controlHeating,
        canManage: canManage,
        onSetup: () => Navigator.of(context).push(AppRoute(
          builder: (_) => ViessmannScreen(
              viessmann: widget.viessmann, faults: widget.faults),
        )),
      );
    }

    // Światła mogą pochodzić z Tuya, a światła i rolety z innych marek, także bez bramki Mobilus.
    final showContent = session.phase == SessionPhase.connected ||
        (lights && widget.tuya.lights.isNotEmpty) ||
        widget.sources
            .any((s) => lights ? s.lights.isNotEmpty : s.covers.isNotEmpty);

    if (!showContent) {
      switch (session.phase) {
        case SessionPhase.restoring:
        case SessionPhase.connecting:
          return const _HomeSkeleton();
        case SessionPhase.loggedOut:
          return _EmptyState(
            icon: Icons.router_outlined,
            title: 'Połącz z bramką Mobilus',
            message: canManage
                ? 'Podaj adres i dane bramki Cosmo GTW, żeby zobaczyć rolety'
                    '${lights ? ' i przełączniki. Światła Tuya dodasz w osobnym kroku.' : '.'}'
                : 'Poproś administratora o połączenie aplikacji z bramką.',
            actionLabel: canManage ? 'Połącz z bramką' : null,
            onAction: _connectGateway,
            secondaryLabel: canManage && lights ? 'Dodaj światła Tuya' : null,
            onSecondary: _openTuya,
          );
        case SessionPhase.connected:
          break;
      }
    }

    final permissions = widget.account.permissions;
    final canControl =
        lights ? permissions.controlLights : permissions.controlBlinds;

    final lightGroups = lights
        ? _lightGroups()
        : const <({String id, String title, List<SmartLight> items})>[];
    final blindGroups = lights
        ? const <({String id, String title, List<_Cover> items})>[]
        : _blindGroups();
    final isEmpty = lights ? lightGroups.isEmpty : blindGroups.isEmpty;

    return RefreshIndicator(
      onRefresh: () async {
        await session.refresh();
        await widget.tuya.refresh();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          if (!canControl)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _Notice(
                icon: Icons.lock_outline,
                text: lights
                    ? 'Ten profil nie ma uprawnień do sterowania światłami.'
                    : 'Ten profil nie ma uprawnień do sterowania roletami.',
              ),
            )
          else if (widget.account.active?.role == ProfileRole.restricted)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: _Notice(
                icon: Icons.info_outline,
                text:
                    'Możesz włączać i wyłączać światła i rolety. Sceny i ustawienia zmienia administrator.',
              ),
            ),
          if (!_tipSeen && canControl && !isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _Notice(
                icon: Icons.touch_app_outlined,
                text: lights
                    ? 'Dotknij światła, żeby je przełączyć. Przytrzymaj, żeby zobaczyć szczegóły.'
                    : 'Przytrzymaj rolety, żeby otworzyć duży suwak pozycji.',
                onClose: _dismissTip,
              ),
            ),
          if (lights)
            _lightsHeader(context, canControl)
          else
            _blindsHeader(context, canControl),
          const SizedBox(height: 12),
          if (isEmpty)
            _EmptyState(
              icon: lights ? Icons.lightbulb_outline : Icons.blinds_outlined,
              title: lights
                  ? 'Jeszcze nie ma tu świateł'
                  : 'Jeszcze nie ma tu rolet',
              message: lights
                  ? 'Pojawią się tu przełączniki Mobilus i włączniki Tuya.'
                  : 'Dodaj silniki w panelu bramki i odśwież listę.',
              actionLabel: lights && canManage ? 'Dodaj światła Tuya' : null,
              onAction: _openTuya,
            )
          else if (lights)
            ResponsiveColumns(children: [
              for (var i = 0; i < lightGroups.length; i++)
                _section(
                  index: i,
                  id: 'lights_${lightGroups[i].id}',
                  title: lightGroups[i].title,
                  summary: _lightSummary(lightGroups[i].items),
                  children: [
                    if (_lightsBulk(lightGroups[i].items, canControl)
                        case final bulk?)
                      bulk,
                    for (final l in lightGroups[i].items)
                      LightTile(
                        onDetails: () => _showLightSheet(l.key, canControl),
                        name: l.name,
                        on: l.on,
                        status: l.status,
                        enabled: canControl && l.available,
                        trailingIcon: l.icon,
                        onChanged: (value) => _setLight(l, value),
                      ),
                  ],
                ),
            ])
          else
            ResponsiveColumns(children: [
              for (var i = 0; i < blindGroups.length; i++)
                _section(
                  index: i,
                  id: 'blinds_${blindGroups[i].id}',
                  title: blindGroups[i].title,
                  summary: blindGroups[i].items.length == 1
                      ? '1 roleta'
                      : '${blindGroups[i].items.length} rolet',
                  children: [
                    if (_blindsBulk(blindGroups[i].items, canControl)
                        case final bulk?)
                      bulk,
                    for (final c in blindGroups[i].items)
                      _coverTile(c, canControl),
                  ],
                ),
            ]),
        ],
      ),
    );
  }

  /// Zakładka Klimat: odczyty czujników pogrupowane w pokoje.
  Widget _climateBody() {
    final groups = _sensorGroups();
    return RefreshIndicator(
      onRefresh: widget.tuya.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          if (widget.weather case final w? when w.hasPlace)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: WeatherCard(weather: w, onChangePlace: _openWeather),
            )
          else if (widget.weather != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.wb_sunny_outlined),
                  title: const Text('Dodaj pogodę'),
                  subtitle: const Text('Prognoza dla Twojej miejscowości'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openWeather,
                ),
              ),
            ),
          if (groups.isEmpty)
            const _Notice(
              icon: Icons.thermostat,
              text: 'Nie dodano jeszcze czujników temperatury i wilgotności. '
                  'Zaimportuj urządzenia Tuya w Ustawienia › Światła Tuya.',
            ),
          ResponsiveColumns(children: [
            for (var i = 0; i < groups.length; i++)
              _section(
                index: i,
                id: 'climate_${groups[i].id}',
                title: groups[i].title,
                summary: _climateSummary(groups[i].items),
                children: [
                  for (final s in groups[i].items)
                    SensorTile(
                      name: s.name,
                      temperature: s.temperature,
                      humidity: s.humidity,
                      battery: s.battery,
                      updatedAt: s.updatedAt,
                      available: s.available && s.hasReading,
                      onTap: () => showSensorSheet(context,
                          sensor: s, canEdit: widget.account.isAdmin),
                    ),
                ],
              ),
          ]),
        ],
      ),
    );
  }

  Future<void> _openWeather() => Navigator.of(context).push(AppRoute(
        builder: (_) => WeatherScreen(weather: widget.weather!),
      ));

  String _climateSummary(List<SmartSensor> sensors) {
    final temps = [
      for (final s in sensors)
        if (s.temperature != null) s.temperature!
    ];
    if (temps.isEmpty)
      return sensors.length == 1 ? '1 czujnik' : '${sensors.length} czujniki';
    return formatTemperature(temps.reduce((a, b) => a + b) / temps.length);
  }

  Widget _section({
    required int index,
    required String id,
    required String title,
    required String summary,
    required List<Widget> children,
  }) {
    return FadeUp(
      index: index,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: RoomSection(
          title: title,
          summary: summary,
          open: _open[id] ?? true,
          onToggle: () => setState(() => _open[id] = !(_open[id] ?? true)),
          children: children,
        ),
      ),
    );
  }

  String _lightSummary(List<SmartLight> lights) {
    final on = lights.where((l) => l.on == true).length;
    return on == 0 ? 'wszystko wyłączone' : '$on z ${lights.length} włączone';
  }

  Future<void> _openTuya() => Navigator.of(context).push(AppRoute(
        builder: (_) => TuyaScreen(tuya: widget.tuya, rooms: widget.rooms),
      ));

  Widget _lightsHeader(BuildContext context, bool canControl) {
    final theme = Theme.of(context);
    final all = _visibleLights().toList();
    final on = all.where((l) => l.on == true).length;
    final tuya = widget.tuya;
    final local =
        tuya.devices.where((d) => tuya.routeOf(d.id) == TuyaRoute.local).length;
    final cloud =
        tuya.devices.where((d) => tuya.routeOf(d.id) == TuyaRoute.cloud).length;
    final sources = [
      if (widget.session.phase == SessionPhase.connected) 'Mobilus',
      if (tuya.hasDevices)
        'Tuya${local > 0 ? ' · lokalnie $local' : ''}${cloud > 0 ? ' · chmura $cloud' : ''}',
    ].join(' + ');
    final info = Row(
      children: [
        Icon(
            cloud > 0 && local == 0 && tuya.hasDevices
                ? Icons.cloud_outlined
                : Icons.wifi,
            size: 18,
            color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text('$sources · $on z ${all.length} włączone',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ],
    );
    final button = FilledButton.tonal(
      onPressed: canControl && all.any((l) => l.on == true && l.available)
          ? _lightsOff
          : null,
      style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40), shape: const StadiumBorder()),
      child: const Text('Wyłącz wszystkie'),
    );
    // Przy większej czcionce systemowej przycisk nie mieści się obok tekstu.
    if (MediaQuery.textScalerOf(context).scale(1) > 1.2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [info, const SizedBox(height: 8), button],
      );
    }
    return Row(
        children: [Expanded(child: info), const SizedBox(width: 8), button]);
  }

  Widget _blindsHeader(BuildContext context, bool canControl) {
    Widget button(IconData icon, String label, String command) => Expanded(
          child: FilledButton.tonal(
            onPressed: canControl ? () => _allBlinds(command) : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              shape: const StadiumBorder(),
              padding: EdgeInsets.zero,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 4),
                  Text(label)
                ],
              ),
            ),
          ),
        );
    return Row(
      children: [
        button(Icons.keyboard_arrow_up_rounded, 'Wszystkie', 'UP'),
        const SizedBox(width: 8),
        button(Icons.stop_rounded, 'Stop', 'STOP'),
        const SizedBox(width: 8),
        button(Icons.keyboard_arrow_down_rounded, 'Wszystkie', 'DOWN'),
      ],
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    // Przewijalny, ale bez przewijania: na niskim ekranie z dużą czcionką nic nie wystaje.
    return const SingleChildScrollView(
      physics: NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        children: [
          Align(
              alignment: Alignment.centerLeft,
              child: Skeleton(height: 32, width: 220, radius: 16)),
          SizedBox(height: 14),
          Skeleton(height: 170),
          SizedBox(height: 12),
          Skeleton(height: 130),
          SizedBox(height: 12),
          Skeleton(height: 64),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.onClose});

  final IconData icon;
  final String text;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          if (onClose != null)
            IconButton(
              tooltip: 'Zamknij wskazówkę',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}

/// Suwak jasności w arkuszu światła; polecenie idzie dopiero po puszczeniu suwaka.
class _BrightnessSlider extends StatefulWidget {
  const _BrightnessSlider(
      {required this.value, required this.enabled, required this.onChanged});

  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  State<_BrightnessSlider> createState() => _BrightnessSliderState();
}

class _BrightnessSliderState extends State<_BrightnessSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final value = (_drag ?? widget.value.toDouble()).clamp(1, 100).toDouble();
    return Row(
      children: [
        const Icon(Icons.brightness_low, size: 20),
        Expanded(
          child: Slider(
            value: value,
            min: 1,
            max: 100,
            label: 'Jasność ${value.round()}%',
            onChanged: widget.enabled ? (v) => setState(() => _drag = v) : null,
            onChangeEnd: widget.enabled
                ? (v) {
                    widget.onChanged(v.round());
                    setState(() => _drag = null);
                  }
                : null,
          ),
        ),
        const Icon(Icons.brightness_high, size: 20),
      ],
    );
  }
}

class _BulkRow extends StatelessWidget {
  const _BulkRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Wrap(spacing: 8, runSpacing: 4, children: children),
      );
}

class _BulkButton extends StatelessWidget {
  const _BulkButton(
      {required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: const StadiumBorder(),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: FadeUp(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                    color: scheme.primaryContainer, shape: BoxShape.circle),
                child: Icon(icon, size: 30, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(height: 16),
              Text(title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              if (actionLabel != null) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(shape: const StadiumBorder()),
                  child: Text(actionLabel!),
                ),
              ],
              if (secondaryLabel != null) ...[
                const SizedBox(height: 8),
                TextButton(
                    onPressed: onSecondary, child: Text(secondaryLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Roleta z bramki Mobilus albo z innej marki.
class _Cover {
  _Cover.mobilus(Device d)
      : key = RoomsController.mobilusKey(d.id),
        device = d,
        smart = null;

  _Cover.smart(SmartCover c)
      : key = c.key,
        device = null,
        smart = c;

  final String key;
  final Device? device;
  final SmartCover? smart;
}

/// Zakładka Ogrzewanie: odczyt co kilka minut tylko wtedy, gdy jest otwarta.
class _HeatingTab extends StatefulWidget {
  const _HeatingTab({
    required this.viessmann,
    required this.canControl,
    required this.canManage,
    required this.onSetup,
  });

  final ViessmannController viessmann;
  final bool canControl;
  final bool canManage;
  final VoidCallback onSetup;

  @override
  State<_HeatingTab> createState() => _HeatingTabState();
}

class _HeatingTabState extends State<_HeatingTab> {
  @override
  void initState() {
    super.initState();
    // Odroczone, bo pierwszy odczyt powiadamia słuchaczy, a budowanie jeszcze trwa.
    scheduleMicrotask(widget.viessmann.startPolling);
  }

  @override
  void dispose() {
    widget.viessmann.stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => widget.viessmann.refresh(force: true),
      child: HeatingView(
        viessmann: widget.viessmann,
        canControl: widget.canControl,
        canManage: widget.canManage,
        onSetup: widget.onSetup,
      ),
    );
  }
}
