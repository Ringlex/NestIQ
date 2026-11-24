import 'package:flutter/material.dart';

import '../state/rooms_controller.dart';
import '../tuya/tuya_cloud_client.dart';
import '../tuya/tuya_controller.dart';
import '../tuya/tuya_models.dart';
import '../widgets/forms.dart';
import '../widgets/motion.dart';

/// Konfiguracja świateł Tuya: dane chmury, import urządzeń, tryb połączenia,
/// adresy w sieci lokalnej.
class TuyaScreen extends StatefulWidget {
  const TuyaScreen({super.key, required this.tuya, required this.rooms});

  final TuyaController tuya;
  final RoomsController rooms;

  @override
  State<TuyaScreen> createState() => _TuyaScreenState();
}

class _TuyaScreenState extends State<TuyaScreen> {
  late final _accessId =
      TextEditingController(text: widget.tuya.credentials?.accessId ?? '');
  late final _secret =
      TextEditingController(text: widget.tuya.credentials?.accessSecret ?? '');
  late TuyaRegion _region = widget.tuya.credentials?.region ?? TuyaRegion.eu;
  bool _editing = false;
  bool _importing = false;
  bool _scanning = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _accessId.dispose();
    _secret.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _import() async {
    final id = _accessId.text.trim();
    final secret = _secret.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      setState(() => _error =
          'Podaj Access ID i Access Secret z projektu na iot.tuya.com.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final result = await widget.tuya.importFromCloud(
        TuyaCloudCredentials(
            accessId: id, accessSecret: secret, region: _region),
      );
      _toast(result.total == 0
          ? 'Nie znaleziono włączników. Sprawdź, czy konto Twojej aplikacji Tuya jest powiązane z projektem.'
          : 'Zaimportowano urządzenia: ${result.total} (nowych: ${result.added}).');
      if (mounted) setState(() => _editing = false);
      if (result.total > 0) _scan(silent: true);
    } on TuyaCloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Ponowny import na zapisanych danych, bez wpisywania ich od nowa.
  Future<void> _refreshFromCloud() async {
    final saved = widget.tuya.credentials;
    if (saved == null) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final result = await widget.tuya.importFromCloud(saved);
      _toast(
          'Odświeżono urządzenia: ${result.total} (nowych: ${result.added}).');
    } on TuyaCloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  static String _mask(String value) =>
      value.length <= 4 ? '••••' : '${value.substring(0, 4)}••••••••';

  Widget _summary(TuyaCloudCredentials saved) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Dane chmury zapisane na tym telefonie',
                      style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
                'Access ID: ${_mask(saved.accessId)}\nAccess Secret: ••••••••••••\n'
                'Centrum danych: ${saved.region.label}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Text(
                'Widoczne tylko w Ustawieniach, czyli dla administratora. '
                'Potrzebne do odświeżania listy urządzeń i sterowania przez chmurę poza domem.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ErrorBanner(_error),
            const SizedBox(height: 14),
            LoadingButton(
              label: 'Odśwież urządzenia z chmury',
              busyLabel: 'Importowanie…',
              busy: _importing,
              onPressed: _refreshFromCloud,
            ),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton(
                  onPressed: _importing
                      ? null
                      : () => setState(() {
                            _accessId.text = saved.accessId;
                            _secret.text = '';
                            _region = saved.region;
                            _error = null;
                            _editing = true;
                          }),
                  child: const Text('Zmień dane'),
                ),
                TextButton(
                  onPressed: _importing ? null : widget.tuya.clearCredentials,
                  style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error),
                  child: const Text('Usuń z telefonu'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scan({bool silent = false}) async {
    setState(() => _scanning = true);
    try {
      final found = await widget.tuya.discover();
      if (!silent) {
        _toast(found == 0
            ? 'Nie znaleziono urządzeń w sieci. Wpisz adresy IP ręcznie albo użyj chmury.'
            : 'Znaleziono w sieci: $found z ${widget.tuya.devices.length}.');
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _edit(TuyaDevice device) async {
    final ip = TextEditingController(text: device.ip ?? '');
    final name = TextEditingController(text: device.name);
    var version = device.version;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(device.name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nazwa')),
                const SizedBox(height: 12),
                TextField(
                  controller: ip,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Adres IP w sieci domowej',
                    helperText:
                        'Zostaw puste, żeby sterować tylko przez chmurę.',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: version,
                  decoration:
                      const InputDecoration(labelText: 'Wersja protokołu'),
                  items: const [
                    DropdownMenuItem(value: '3.3', child: Text('3.3')),
                    DropdownMenuItem(value: '3.4', child: Text('3.4')),
                    DropdownMenuItem(value: '3.5', child: Text('3.5')),
                  ],
                  onChanged: (v) => setLocal(() => version = v ?? version),
                ),
                const SizedBox(height: 8),
                Text('Wersja wykrywa się sama przy pierwszym połączeniu.',
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text('ID: ${device.id}',
                    style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error),
              child: const Text('Usuń'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Anuluj')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, 'save'),
                child: const Text('Zapisz')),
          ],
        ),
      ),
    );
    final newIp = ip.text.trim();
    final newName = name.text.trim();
    ip.dispose();
    name.dispose();
    if (action == 'delete') {
      await widget.tuya.removeDevice(device.id);
    } else if (action == 'save') {
      await widget.tuya.updateDevice(device.copyWith(
        name: newName.isEmpty ? device.name : newName,
        version: version,
        ip: newIp,
        clearIp: newIp.isEmpty,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tuya = widget.tuya;

    return Scaffold(
      appBar: AppBar(title: const Text('Światła Tuya')),
      body: ListenableBuilder(
        listenable: tuya,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text('Tryb połączenia', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<TuyaMode>(
              showSelectedIcon: false,
              segments: [
                for (final m in TuyaMode.values)
                  ButtonSegment(value: m, label: Text(m.label)),
              ],
              selected: {tuya.mode},
              onSelectionChanged: (s) => tuya.setMode(s.first),
            ),
            const SizedBox(height: 6),
            Text(
              switch (tuya.mode) {
                TuyaMode.auto =>
                  'W domu lokalnie (szybko, bez internetu), poza domem przez chmurę Tuya.',
                TuyaMode.local =>
                  'Tylko sieć domowa. Poza domem światła są niedostępne.',
                TuyaMode.cloud =>
                  'Zawsze przez chmurę Tuya. Wymaga internetu i jest wolniejsze.',
              },
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Text('Chmura Tuya', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (tuya.credentials != null && !_editing)
              _summary(tuya.credentials!)
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _accessId,
                        enabled: !_importing,
                        autocorrect: false,
                        decoration: const InputDecoration(
                            labelText: 'Access ID',
                            prefixIcon: Icon(Icons.key_outlined)),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _secret,
                        enabled: !_importing,
                        obscureText: _obscure,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: 'Access Secret',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Pokaż' : 'Ukryj',
                            icon: Icon(_obscure
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<TuyaRegion>(
                        isExpanded: true,
                        value: _region,
                        decoration: const InputDecoration(
                            labelText: 'Centrum danych',
                            prefixIcon: Icon(Icons.public)),
                        items: [
                          for (final r in TuyaRegion.values)
                            DropdownMenuItem(value: r, child: Text(r.label)),
                        ],
                        onChanged: _importing
                            ? null
                            : (v) => setState(() => _region = v ?? _region),
                      ),
                      ErrorBanner(_error),
                      const SizedBox(height: 16),
                      LoadingButton(
                        label: tuya.credentials != null
                            ? 'Zapisz i odśwież urządzenia'
                            : 'Zapisz i zaimportuj urządzenia',
                        busyLabel: 'Importowanie…',
                        busy: _importing,
                        onPressed: _import,
                      ),
                      if (tuya.credentials != null)
                        TextButton(
                          onPressed: _importing
                              ? null
                              : () => setState(() => _editing = false),
                          child: const Text('Anuluj'),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                title: const Text('Skąd wziąć te dane?'),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Text(
                      '1. Na iot.tuya.com załóż konto i projekt (Cloud → Development → Create Cloud Project, '
                      'branża Smart Home, centrum danych jak wyżej).\n'
                      '2. W projekcie włącz usługi: IoT Core oraz Authorization Token Management.\n'
                      '3. Devices → Link App Account → Add App Account: zeskanuj kod w aplikacji Tuya (lub Smart Life): '
                      'Ja → ikona skanowania w rogu. Centrum danych projektu musi być tym samym, '
                      'w którym masz konto w aplikacji (dla Polski zwykle Europa).\n'
                      '4. W Overview skopiuj Access ID i Access Secret.\n\n'
                      'Klucze lokalne potrzebne do sterowania w sieci domowej wydaje tylko chmura Tuya. '
                      'Importujesz je raz, potem światła działają lokalnie, bez chmury.\n\n'
                      'Uwaga: darmowy okres próbny API Tuya trzeba co jakiś czas przedłużać na iot.tuya.com. '
                      'Gdy wygaśnie, sterowanie lokalne dalej działa, a przez chmurę – nie.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                    child:
                        Text('Urządzenia', style: theme.textTheme.titleSmall)),
                IconButton(
                  tooltip: 'Sprawdź połączenia ponownie',
                  onPressed: tuya.hasDevices ? tuya.refresh : null,
                  icon: const Icon(Icons.refresh),
                ),
                TextButton.icon(
                  onPressed: _scanning || !tuya.hasDevices ? null : _scan,
                  icon: _scanning
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_find_outlined),
                  label: Text(_scanning ? 'Szukanie…' : 'Skanuj sieć'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (!tuya.hasDevices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Brak urządzeń. Zaimportuj je z chmury Tuya powyżej.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              )
            else
              for (var i = 0; i < tuya.devices.length; i++)
                FadeUp(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        leading: Icon(
                            _routeIcon(tuya.routeOf(tuya.devices[i].id)),
                            color: scheme.primary),
                        title: Text(tuya.devices[i].name),
                        subtitle: Text(
                          '${_routeLabel(tuya.routeOf(tuya.devices[i].id))} · '
                          '${tuya.devices[i].ip ?? 'bez adresu IP'} · v${tuya.devices[i].version} · '
                          '${tuya.devices[i].channels.isEmpty ? 'czujnik (odczyt przez chmurę)' : 'przyciski: ${tuya.devices[i].channels.length}'}'
                          '${tuya.routeOf(tuya.devices[i].id) == TuyaRoute.offline && tuya.problemOf(tuya.devices[i].id) != null ? '\n${tuya.problemOf(tuya.devices[i].id)}' : ''}',
                        ),
                        isThreeLine: tuya.routeOf(tuya.devices[i].id) ==
                                TuyaRoute.offline &&
                            tuya.problemOf(tuya.devices[i].id) != null,
                        trailing: const Icon(Icons.edit_outlined),
                        onTap: () => _edit(tuya.devices[i]),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  static IconData _routeIcon(TuyaRoute route) => switch (route) {
        TuyaRoute.local => Icons.wifi,
        TuyaRoute.cloud => Icons.cloud_outlined,
        TuyaRoute.connecting => Icons.sync,
        TuyaRoute.offline => Icons.cloud_off_outlined,
      };

  static String _routeLabel(TuyaRoute route) => switch (route) {
        TuyaRoute.local => 'lokalnie',
        TuyaRoute.cloud => 'chmura',
        TuyaRoute.connecting => 'łączenie',
        TuyaRoute.offline => 'niedostępne',
      };
}
