import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../account/account_models.dart';
import '../widgets/motion.dart';
import 'pin_screen.dart';
import '../widgets/responsive.dart';

/// „Kto korzysta?” – wybór profilu domownika po zalogowaniu na konto.
class ProfilePickerScreen extends StatefulWidget {
  const ProfilePickerScreen({super.key, required this.account});

  final AccountController account;

  @override
  State<ProfilePickerScreen> createState() => _ProfilePickerScreenState();
}

class _ProfilePickerScreenState extends State<ProfilePickerScreen> {
  String? _busyId;

  Future<void> _choose(Profile profile) async {
    if (_busyId != null) return;
    if (profile.hasPin) {
      await Navigator.of(context).push(AppRoute(
        builder: (_) => PinScreen(account: widget.account, profile: profile),
      ));
      return;
    }
    setState(() => _busyId = profile.id);
    try {
      await widget.account.selectProfile(profile.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profiles = widget.account.profiles;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            // Całość w jednej przewijanej liście: przy dużej czcionce albo na małym
            // ekranie nic się nie przepełnia, tylko przewija.
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FadeUp(
                          child: Row(
                            children: [
                              Icon(Icons.roofing_rounded,
                                  color: scheme.primary),
                              const SizedBox(width: 10),
                              Text('NestIQ',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: scheme.primary)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        FadeUp(
                          index: 1,
                          child: Text('Kto korzysta?',
                              style: theme.textTheme.displaySmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(height: 6),
                        FadeUp(
                          index: 2,
                          child: Text('Dotknij swojego profilu.',
                              style: theme.textTheme.bodyLarge
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverGrid(
                    // Stała wysokość skalowana z czcionką: stosunek boków obcinał kartę
                    // przy większym tekście systemowym.
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 168 +
                          40 *
                              (MediaQuery.textScalerOf(context).scale(1) - 1)
                                  .clamp(0, 2),
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => FadeUp(
                        index: i + 3,
                        child: _ProfileCard(
                          profile: profiles[i],
                          busy: _busyId == profiles[i].id,
                          onTap: () => _choose(profiles[i]),
                        ),
                      ),
                      childCount: profiles.length,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Center(
                      child: TextButton(
                        onPressed: widget.account.logout,
                        child: const Text('Wyloguj konto'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard(
      {required this.profile, required this.busy, required this.onTap});

  final Profile profile;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label:
          'Profil ${profile.name}${profile.hasPin ? ', chroniony PIN-em' : ''}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    ProfileAvatar(profile: profile, size: 72),
                    if (busy)
                      const SizedBox.square(
                        dimension: 80,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium),
                    ),
                    if (profile.hasPin) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.lock_outline,
                          size: 16, color: scheme.onSurfaceVariant),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: profile.isAdmin
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(profile.role.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: profile.isAdmin
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
