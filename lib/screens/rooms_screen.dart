import 'package:flutter/material.dart';

import '../mobilus/device_info.dart';
import '../mobilus/proto.dart';
import '../state/rooms_controller.dart';
import '../devices/smart_device.dart';
import '../state/session_controller.dart';
import '../tuya/tuya_controller.dart';
import '../widgets/motion.dart';

/// Pokoje i przypisanie do nich świateł oraz rolet (administrator).
class RoomsScreen extends StatelessWidget {
  const RoomsScreen(
      {super.key,
      required this.rooms,
      required this.session,
      required this.tuya,
      this.sources = const []});

  final RoomsController rooms;
  final SessionController session;
  final TuyaController tuya;
  final List<DeviceSource> sources;

  Future<String?> _askName(BuildContext context, {String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(initial.isEmpty ? 'Nowy pokój' : 'Zmień nazwę'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          textCapitalization: TextCapitalization.sentences,
          decoration:
              const InputDecoration(labelText: 'Nazwa pokoju', counterText: ''),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Zapisz')),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _add(BuildContext context) async {
    final name = await _askName(context);
    if (name != null && name.isNotEmpty) await rooms.add(name);
  }

  Future<void> _assign(BuildContext context, Room room) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _AssignSheet(
          room: room,
          rooms: rooms,
          session: session,
          tuya: tuya,
          sources: sources),
    );
  }

  Future<void> _remove(BuildContext context, Room room) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Usunąć pokój ${room.name}?'),
        content:
            const Text('Urządzenia z tego pokoju trafią do grupy „Pozostałe”.'),
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
    if (ok == true) await rooms.remove(room.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pokoje i grupy')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: const Text('Nowy pokój'),
      ),
      body: ListenableBuilder(
        listenable: rooms,
        builder: (context, _) {
          final theme = Theme.of(context);
          if (rooms.rooms.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Dodaj pokoje (np. Salon, Kuchnia), a potem przypisz do nich światła i rolety. '
                  'Na ekranie Dom będą pogrupowane.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              for (var i = 0; i < rooms.rooms.length; i++)
                FadeUp(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: ListTile(
                        title: Text(rooms.rooms[i].name),
                        subtitle: Text(
                            'Urządzeń: ${rooms.keysIn(rooms.rooms[i].id).length}'),
                        onTap: () => _assign(context, rooms.rooms[i]),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Więcej',
                          onSelected: (action) async {
                            final room = rooms.rooms[i];
                            if (action == 'rename') {
                              final name =
                                  await _askName(context, initial: room.name);
                              if (name != null && name.isNotEmpty)
                                await rooms.rename(room.id, name);
                            } else if (context.mounted) {
                              await _remove(context, room);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'rename', child: Text('Zmień nazwę')),
                            PopupMenuItem(value: 'delete', child: Text('Usuń')),
                          ],
                        ),
                      ),
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

class _AssignSheet extends StatelessWidget {
  const _AssignSheet({
    required this.room,
    required this.rooms,
    required this.session,
    required this.tuya,
    required this.sources,
  });

  final Room room;
  final RoomsController rooms;
  final SessionController session;
  final TuyaController tuya;
  final List<DeviceSource> sources;

  @override
  Widget build(BuildContext context) {
    // Wszystko, co da się przypisać do pokoju: klucz, nazwa i rodzaj.
    final items = <({String key, String name, String kind})>[
      for (final Device d in session.devices)
        if (MobilusDeviceType.fromCode(d.type) case final type
            when type.isSwitch || type.isCover || type.isGarage)
          (
            key: RoomsController.mobilusKey(d.id),
            name: d.name.isEmpty ? 'Urządzenie ${d.id}' : d.name,
            kind: type.isSwitch ? 'Światło' : 'Roleta',
          ),
      for (final l in tuya.lights)
        (
          key: RoomsController.tuyaKey(l.device.id, l.channel.dpId),
          name: l.device.channelLabel(l.channel),
          kind: 'Światło Tuya',
        ),
      for (final d in tuya.sensorDevices)
        (
          key: RoomsController.tuyaSensorKey(d.id),
          name: d.name,
          kind: 'Czujnik Tuya'
        ),
      for (final source in sources) ...[
        for (final s in source.sensors)
          (key: s.key, name: s.name, kind: 'Czujnik ${source.title}'),
        for (final l in source.lights)
          (key: l.key, name: l.name, kind: 'Światło ${source.title}'),
        for (final c in source.covers)
          (key: c.key, name: c.name, kind: 'Roleta ${source.title}'),
      ],
    ];

    return ListenableBuilder(
      listenable: rooms,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Urządzenia w pokoju ${room.name}',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'Najpierw połącz się z bramką albo dodaj światła Tuya.'),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in items)
                        CheckboxListTile(
                          value: rooms.roomOfKey(item.key) == room.id,
                          title: Text(item.name),
                          subtitle: Text(_subtitle(item.kind, item.key)),
                          onChanged: (v) => rooms.assignKey(
                              item.key, v == true ? room.id : null),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(String kind, String key) {
    final other = rooms.byId(rooms.roomOfKey(key) ?? '');
    return other == null || other.id == room.id
        ? kind
        : '$kind · teraz w: ${other.name}';
  }
}
