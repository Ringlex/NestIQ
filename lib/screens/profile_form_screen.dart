import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/account_controller.dart';
import '../account/account_models.dart';
import '../state/rooms_controller.dart';
import '../widgets/forms.dart';
import '../widgets/motion.dart';

/// Formularz profilu: pierwszy profil konta, nowy profil domownika albo edycja.
class ProfileFormScreen extends StatefulWidget {
  /// Pierwszy profil konta – zawsze administrator, bez wyboru roli.
  const ProfileFormScreen.first(
      {super.key, required this.account, required this.rooms})
      : profile = null,
        first = true;

  const ProfileFormScreen.create(
      {super.key, required this.account, required this.rooms})
      : profile = null,
        first = false;

  const ProfileFormScreen.edit(
      {super.key,
      required this.account,
      required this.rooms,
      required Profile this.profile})
      : first = false;

  final AccountController account;
  final RoomsController rooms;
  final Profile? profile;
  final bool first;

  @override
  State<ProfileFormScreen> createState() => _ProfileFormScreenState();
}

class _ProfileFormScreenState extends State<ProfileFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  final _pin = TextEditingController();
  late String _color = widget.profile?.color ?? Profile.palette.first;
  late ProfileRole _role = widget.first
      ? ProfileRole.admin
      : widget.profile?.role ?? ProfileRole.member;
  late Permissions _permissions = widget.profile?.permissions ??
      Permissions.preset(widget.first ? ProfileRole.admin : _role);
  late final Set<String> _roomIds = {...?widget.profile?.allowedRooms};
  late bool _usePin = false;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.profile != null;

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  Profile get _preview => Profile(
        id: widget.profile?.id ?? '',
        name: _name.text.trim().isEmpty ? '?' : _name.text.trim(),
        color: _color,
        role: _role,
        hasPin: false,
        permissions: _permissions,
      );

  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final name = _name.text.trim();
    final pin = _usePin ? _pin.text : null;
    final rooms = _role == ProfileRole.admin || _roomIds.isEmpty
        ? null
        : _roomIds.toList();

    await _guard(() async {
      if (widget.first) {
        await widget.account
            .createFirstProfile(name: name, color: _color, pin: pin);
        return;
      }
      if (_editing) {
        await widget.account.updateProfile(
          widget.profile!.id,
          name: name,
          color: _color,
          role: _role,
          permissions: _permissions,
          allowedRooms: rooms,
          resetRooms: rooms == null,
        );
      } else {
        await widget.account.createProfile(
          name: name,
          color: _color,
          role: _role,
          permissions: _permissions,
          allowedRooms: rooms,
          pin: pin,
        );
      }
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Usunąć profil ${widget.profile!.name}?'),
        content: const Text(
            'Profil i jego ustawienia znikną. Urządzeń w domu to nie zmieni.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Usuń profil'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      await widget.account.deleteProfile(widget.profile!.id);
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _changePin() async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => const _PinDialog(),
    );
    if (value == null) return;
    await _guard(() async {
      await widget.account.setPin(widget.profile!.id, value);
      _toast('PIN zapisany.');
    });
  }

  Future<void> _removePin() => _guard(() async {
        await widget.account.setPin(widget.profile!.id, null);
        _toast('PIN usunięty. Profil wchodzi bez kodu.');
      });

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _setRole(ProfileRole role) => setState(() {
        _role = role;
        _permissions = Permissions.preset(role);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = _editing
        ? widget.account.profiles
                .where((p) => p.id == widget.profile!.id)
                .firstOrNull ??
            widget.profile!
        : null;
    final canEditPermissions = _role != ProfileRole.admin;

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        if (widget.first) ...[
          FadeUp(
            child: Text('Utwórz swój profil.',
                style: theme.textTheme.displaySmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          Text(
            'To pierwszy profil na koncie, więc będzie administratorem domu. Resztę domowników dodasz później.',
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
        ],
        Center(child: ProfileAvatar(profile: _preview, size: 88)),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final hex in Profile.palette)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Semantics(
                  button: true,
                  selected: hex == _color,
                  label: 'Kolor awatara',
                  child: GestureDetector(
                    onTap: () => setState(() => _color = hex),
                    child: AnimatedContainer(
                      duration: Motion.toggle,
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Profile.parseColor(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: hex == _color
                              ? scheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        TextFormField(
          controller: _name,
          enabled: !_busy,
          maxLength: 30,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Nazwa profilu',
            hintText: 'np. Mama, Tata, Dziecko',
            counterText: '',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
          validator: (v) =>
              (v ?? '').trim().isEmpty ? 'Podaj nazwę profilu.' : null,
        ),
        if (widget.first) ...[
          const SizedBox(height: 14),
          const _InfoRow(
            icon: Icons.shield_outlined,
            title: 'Administrator',
            subtitle:
                'Pełne uprawnienia. Nie można zmienić dla pierwszego profilu.',
          ),
        ] else ...[
          const SizedBox(height: 20),
          Text('Rola', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ProfileRole>(
            showSelectedIcon: false,
            segments: [
              for (final r in ProfileRole.values)
                ButtonSegment(value: r, label: Text(r.label)),
            ],
            selected: {_role},
            onSelectionChanged: _busy ? null : (s) => _setRole(s.first),
          ),
        ],
        AnimatedSize(
          duration: Motion.expand,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !canEditPermissions
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    Text('Uprawnienia', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Card(
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: const Text('Sterowanie światłami'),
                            value: _permissions.controlLights,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _permissions =
                                    _permissions.copyWith(controlLights: v)),
                          ),
                          SwitchListTile(
                            title: const Text('Sterowanie roletami'),
                            value: _permissions.controlBlinds,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _permissions =
                                    _permissions.copyWith(controlBlinds: v)),
                          ),
                          SwitchListTile(
                            title: const Text('Sterowanie ogrzewaniem'),
                            value: _permissions.controlHeating,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _permissions =
                                    _permissions.copyWith(controlHeating: v)),
                          ),
                          SwitchListTile(
                            title: const Text('Uruchamianie scen'),
                            value: _permissions.runScenes,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _permissions =
                                    _permissions.copyWith(runScenes: v)),
                          ),
                          const ListTile(
                            leading: Icon(Icons.lock_outline),
                            title: Text('Edycja scen i zmiana ustawień'),
                            subtitle: Text('Tylko administrator'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('Dostępne pokoje', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    if (widget.rooms.rooms.isEmpty)
                      Text(
                          'Nie dodano jeszcze pokoi, więc profil widzi wszystko. '
                          'Pokoje dodasz w Ustawieniach.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant))
                    else ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final room in widget.rooms.rooms)
                            FilterChip(
                              label: Text(room.name),
                              selected: _roomIds.contains(room.id),
                              onSelected: _busy
                                  ? null
                                  : (v) => setState(() => v
                                      ? _roomIds.add(room.id)
                                      : _roomIds.remove(room.id)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _roomIds.isEmpty
                            ? 'Nic nie zaznaczono: profil widzi wszystkie pokoje.'
                            : 'Profil widzi tylko zaznaczone pokoje.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 20),
        Text('PIN profilu', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (_editing)
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(current!.hasPin
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined),
                  title: Text(
                      current.hasPin ? 'PIN ustawiony' : 'Profil bez PIN-u'),
                  subtitle: const Text('Pytany przy wyborze profilu'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      OutlinedButton(
                        onPressed: _busy ? null : _changePin,
                        child: Text(current.hasPin ? 'Zmień PIN' : 'Ustaw PIN'),
                      ),
                      if (current.hasPin) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _busy ? null : _removePin,
                          child: const Text('Usuń PIN (reset)'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Zabezpiecz profil PIN-em'),
                  subtitle:
                      const Text('Opcjonalnie. Pytany przy wyborze profilu.'),
                  value: _usePin,
                  onChanged: _busy ? null : (v) => setState(() => _usePin = v),
                ),
                AnimatedSize(
                  duration: Motion.expand,
                  curve: Motion.curve,
                  alignment: Alignment.topCenter,
                  child: _usePin
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: TextFormField(
                            controller: _pin,
                            enabled: !_busy,
                            keyboardType: TextInputType.number,
                            obscureText: true,
                            maxLength: 4,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                                labelText: 'PIN (4 cyfry)', counterText: ''),
                            validator: (v) => _usePin && (v ?? '').length != 4
                                ? 'PIN ma 4 cyfry.'
                                : null,
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ErrorBanner(_error),
        const SizedBox(height: 24),
        LoadingButton(
          label: widget.first
              ? 'Utwórz profil i wejdź'
              : _editing
                  ? 'Zapisz zmiany'
                  : 'Dodaj profil',
          busyLabel: 'Zapisywanie…',
          busy: _busy,
          onPressed: _save,
        ),
        if (_editing) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Usuń profil'),
          ),
        ],
      ],
    );

    return Scaffold(
      appBar: widget.first
          ? AppBar(
              actions: [
                TextButton(
                    onPressed: widget.account.logout,
                    child: const Text('Wyloguj')),
              ],
            )
          : AppBar(
              title: Text(
                  _editing ? 'Profil: ${widget.profile!.name}' : 'Nowy profil'),
            ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480), child: body),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(
      {required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                Text(subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PinDialog extends StatefulWidget {
  const _PinDialog();

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nowy PIN'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        obscureText: true,
        maxLength: 4,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration:
            const InputDecoration(labelText: '4 cyfry', counterText: ''),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Anuluj')),
        FilledButton(
          onPressed: _controller.text.length == 4
              ? () => Navigator.pop(context, _controller.text)
              : null,
          child: const Text('Zapisz'),
        ),
      ],
    );
  }
}
