import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../mobilus/device_info.dart';
import '../mobilus/proto.dart';
import '../state/app_settings.dart';
import '../state/scenes_controller.dart';
import '../state/session_controller.dart';
import '../widgets/gateway_scene_card.dart';
import 'gateway_scene_editor_screen.dart';
import 'scene_editor_screen.dart';
import '../widgets/responsive.dart';

class ScenesScreen extends StatelessWidget {
  const ScenesScreen({
    super.key,
    required this.controller,
    required this.scenes,
    required this.settings,
    required this.account,
  });

  final AccountController account;
  final SessionController controller;
  final ScenesController scenes;
  final AppSettings settings;

  Iterable<Device> get _covers => controller.devices
      .where((d) => MobilusDeviceType.fromCode(d.type).isCover);

  Future<void> _run(
      BuildContext context, String name, Map<int, String> commands) async {
    if (commands.isEmpty) return;
    if (settings.confirmScenes) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Uruchomić „$name”?'),
          content:
              Text('Komendy zostaną wysłane do urządzeń: ${commands.length}.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Anuluj')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Uruchom')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await controller.sendAll(commands);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Uruchomiono: $name')));
  }

  Future<void> _edit(BuildContext context, [Scene? scene]) async {
    final result = await Navigator.of(context).push<Scene>(AppRoute(
      builder: (_) =>
          SceneEditorScreen(devices: controller.devices, scene: scene),
    ));
    if (result != null) await scenes.save(result);
  }

  Future<void> _editGateway(BuildContext context, [GatewayScene? scene]) =>
      Navigator.of(context).push(AppRoute(
        builder: (_) => GatewaySceneEditorScreen(
          devices: controller.devices,
          scene: scene,
          onSave: controller.saveScene,
          onRemove: controller.removeScene,
        ),
      ));

  Future<void> _remove(BuildContext context, Scene scene) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Usunąć „${scene.name}”?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Usuń')),
        ],
      ),
    );
    if (ok == true) await scenes.remove(scene.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canRun = account.permissions.runScenes;
    final canEdit = account.permissions.editScenes;
    final known = {for (final d in controller.devices) d.id};
    final names = {for (final d in controller.devices) d.id: d.name};

    return Scaffold(
      appBar: AppBar(title: const Text('Sceny')),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              heroTag: null,
              onPressed: controller.devices.isEmpty
                  ? null
                  : () => _editGateway(context),
              icon: const Icon(Icons.add),
              label: const Text('Nowa scena'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text('Szybkie akcje', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.arrow_upward),
                label: const Text('Wszystkie w górę'),
                onPressed: !canRun
                    ? null
                    : () => _run(context, 'Wszystkie w górę',
                        {for (final d in _covers) d.id: 'UP'}),
              ),
              ActionChip(
                avatar: const Icon(Icons.arrow_downward),
                label: const Text('Wszystkie w dół'),
                onPressed: !canRun
                    ? null
                    : () => _run(context, 'Wszystkie w dół',
                        {for (final d in _covers) d.id: 'DOWN'}),
              ),
              ActionChip(
                avatar: const Icon(Icons.stop),
                label: const Text('Zatrzymaj wszystkie'),
                onPressed: !canRun
                    ? null
                    : () => _run(context, 'Zatrzymaj wszystkie',
                        {for (final d in _covers) d.id: 'STOP'}),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Sceny', style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
              'Zapisane w bramce – te same co w aplikacji Mobilus na każdym telefonie.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (controller.gatewayScenes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  Icon(Icons.auto_awesome_outlined,
                      size: 48, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text('Brak scen', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                      'Zapisz ustawienia kilku rolet i uruchamiaj je jednym dotknięciem '
                      'albo według harmonogramu.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          for (final scene in controller.gatewayScenes)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GatewaySceneCard(
                scene: scene,
                deviceNames: names,
                onTap: canEdit ? () => _editGateway(context, scene) : null,
                onRun: !canRun
                    ? null
                    : () => _run(context, scene.name, {
                          for (final e in scene.events) e.deviceId: e.value,
                        }),
              ),
            ),
          // Starsze sceny zapisane tylko w telefonie (sprzed obsługi scen bramki).
          if (scenes.scenes.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Na tym telefonie', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
          ],
          for (final scene in scenes.scenes)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.auto_awesome,
                        color: theme.colorScheme.onPrimaryContainer),
                  ),
                  title: Text(scene.name),
                  subtitle: Text('Urządzenia: ${scene.actions.length}'),
                  onTap: canEdit ? () => _edit(context, scene) : null,
                  onLongPress: canEdit ? () => _remove(context, scene) : null,
                  trailing: IconButton.filledTonal(
                    tooltip: 'Uruchom',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: !canRun
                        ? null
                        : () => _run(context, scene.name, {
                              for (final a in scene.actions)
                                if (known.contains(a.deviceId))
                                  a.deviceId: a.value,
                            }),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
