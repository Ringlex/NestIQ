import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../state/rooms_controller.dart';
import '../state/session_controller.dart';
import '../widgets/motion.dart';
import 'profiles_screen.dart';
import '../widgets/responsive.dart';

/// Profil: kto jest zalogowany, zmiana profilu, wylogowanie z konta.
class UserScreen extends StatelessWidget {
  const UserScreen({
    super.key,
    required this.account,
    required this.session,
    required this.rooms,
  });

  final AccountController account;
  final SessionController session;
  final RoomsController rooms;

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wylogować z konta?'),
        content:
            const Text('Na tym telefonie trzeba będzie zalogować się ponownie. '
                'Połączenie z bramką zostaje zapisane.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Wyloguj')),
        ],
      ),
    );
    if (ok == true) await account.logout();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = account.active;

    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListenableBuilder(
        listenable: Listenable.merge([account, session]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const SizedBox(height: 16),
            if (profile != null) ...[
              Center(
                  child:
                      FadeUp(child: ProfileAvatar(profile: profile, size: 80))),
              const SizedBox(height: 12),
              Text(profile.name,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge),
              Text(profile.role.label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 24),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.mail_outline),
                    title: const Text('Konto'),
                    subtitle: Text(account.email ?? '—'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: const Text('Zmień profil'),
                    onTap: account.switchProfile,
                  ),
                  if (account.isAdmin)
                    ListTile(
                      leading: const Icon(Icons.group_outlined),
                      title: const Text('Profile domowników'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(AppRoute(
                        builder: (_) =>
                            ProfilesScreen(account: account, rooms: rooms),
                      )),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.router_outlined),
                    title: const Text('Bramka Mobilus'),
                    subtitle: Text(session.phase == SessionPhase.connected
                        ? '${session.gatewayHost ?? '—'} · ${session.gatewaySerial ?? ''}'
                        : 'Niepołączona'),
                  ),
                  ListTile(
                    leading: Icon(
                        session.connectionLost ? Icons.wifi_off : Icons.wifi),
                    title: const Text('Połączenie'),
                    subtitle:
                        Text(session.connectionLost ? 'Utracone' : 'Połączono'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.devices_other),
                    title: const Text('Urządzenia'),
                    subtitle: Text('${session.devices.length}'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => _confirmLogout(context),
              icon: const Icon(Icons.logout),
              label: const Text('Wyloguj z konta'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
