import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../state/rooms_controller.dart';
import '../widgets/motion.dart';
import 'profile_form_screen.dart';
import '../widgets/responsive.dart';

/// Zarządzanie profilami domowników (administrator).
class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key, required this.account, required this.rooms});

  final AccountController account;
  final RoomsController rooms;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile domowników')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => Navigator.of(context).push(AppRoute(
          builder: (_) =>
              ProfileFormScreen.create(account: account, rooms: rooms),
        )),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Dodaj profil'),
      ),
      body: ListenableBuilder(
        listenable: account,
        builder: (context, _) {
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              for (var i = 0; i < account.profiles.length; i++)
                FadeUp(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                        leading: ProfileAvatar(profile: account.profiles[i]),
                        title: Row(
                          children: [
                            Flexible(child: Text(account.profiles[i].name)),
                            if (account.profiles[i].hasPin) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.lock_outline,
                                  size: 16,
                                  color: theme.colorScheme.onSurfaceVariant),
                            ],
                          ],
                        ),
                        subtitle: Text(
                            account.profiles[i].id == account.active?.id
                                ? '${account.profiles[i].role.label} · to Ty'
                                : account.profiles[i].role.label),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(AppRoute(
                          builder: (_) => ProfileFormScreen.edit(
                            account: account,
                            rooms: rooms,
                            profile: account.profiles[i],
                          ),
                        )),
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
