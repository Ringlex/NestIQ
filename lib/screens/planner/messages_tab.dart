import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../account/account_models.dart';
import '../../household/household_controller.dart';
import '../../widgets/motion.dart';
import 'planner_common.dart';

const quickMessages = [
  'Hej, wychodzę po pracy z koleżanką na kawę, wrócę później',
  'Będę dziś później niż zwykle',
  'Jestem w domu',
  'Kupiłem(am) wszystko z listy',
  'Zadzwoń do mnie, jak możesz',
];

const messageMaxLength = 500;

class MessagesTab extends StatefulWidget {
  const MessagesTab(
      {super.key,
      required this.household,
      required this.account,
      required this.active});

  final HouseholdController household;
  final AccountController account;

  /// Czy zakładka jest widoczna; po wejściu wiadomości oznaczają się jako przeczytane.
  /// Notifier zamiast zwykłej flagi, bo `TabBarView` nie zawsze odświeża kartę podczas skoku.
  final ValueListenable<bool> active;

  @override
  State<MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<MessagesTab> {
  Set<String> _freshIds = {};

  HouseholdController get _h => widget.household;

  @override
  void initState() {
    super.initState();
    widget.active.addListener(_markRead);
    _markRead();
  }

  @override
  void dispose() {
    widget.active.removeListener(_markRead);
    super.dispose();
  }

  /// Zapamiętuje, które wiadomości były nowe (do wyróżnienia), i oznacza je jako przeczytane.
  Future<void> _markRead() async {
    if (!widget.active.value || !mounted) return;
    final me = _h.profileId;
    final unread = [
      for (final m in _h.messages)
        if (!m.read && m.from != me) m.id
    ];
    if (unread.isEmpty) return;
    setState(() => _freshIds = unread.toSet());
    try {
      await _h.markMessagesRead(ids: unread);
    } catch (_) {
      // Spróbujemy ponownie przy następnym wejściu.
    }
  }

  Future<void> _compose() async {
    final others = [
      for (final p in widget.account.profiles)
        if (p.id != _h.profileId) p
    ];
    if (others.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content:
                Text('Dodaj najpierw drugi profil, żeby mieć do kogo pisać.')));
      return;
    }
    final result = await showModalBottomSheet<(String?, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ComposeSheet(recipients: others),
    );
    if (result == null || !mounted) return;
    final ok =
        await guarded(context, () => _h.sendMessage(result.$2, to: result.$1));
    if (ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Wysłano')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ProfileNames.of(widget.account);
    final me = _h.profileId;
    final messages = [..._h.messages]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _compose,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Napisz'),
      ),
      // Wiadomości czyta się jak rozmowę, więc kolumna jest wyśrodkowana i nie rozciąga się na tablecie.
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: RefreshIndicator(
            onRefresh: _h.refreshMessages,
            child: messages.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 80),
                    PlannerEmpty(
                      icon: Icons.chat_bubble_outline,
                      title: 'Brak wiadomości',
                      message: 'Napisz do domowników, np. że wrócisz później. '
                          'Wiadomości znikają po 60 dniach.',
                    ),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final m = messages[i];
                      final mine = m.from == me;
                      final fresh = _freshIds.contains(m.id);
                      final sender = names.profile(m.from);
                      final target = m.to == null
                          ? 'do wszystkich'
                          : 'do: ${names.of(m.to)}';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Card(
                          color: fresh
                              ? theme.colorScheme.secondaryContainer
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (sender != null)
                                  ProfileAvatar(profile: sender, size: 36)
                                else
                                  const CircleAvatar(
                                      radius: 18,
                                      child: Icon(Icons.person_outline)),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${mine ? 'Ty' : names.of(m.from)} · $target',
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                                color: theme.colorScheme
                                                    .onSurfaceVariant),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(m.body,
                                          style: theme.textTheme.bodyLarge),
                                      const SizedBox(height: 4),
                                      Text(
                                          '${dayLabel(m.createdAt)}, ${timeLabel(m.createdAt)}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                  color: theme.colorScheme
                                                      .onSurfaceVariant)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

/// Zwraca `(adresat, treść)`; adresat `null` = wszyscy.
class ComposeSheet extends StatefulWidget {
  const ComposeSheet({super.key, required this.recipients});

  final List<Profile> recipients;

  @override
  State<ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<ComposeSheet> {
  final _text = TextEditingController();
  String? _to;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _valid => _text.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Nowa wiadomość', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Text('Do', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                      label: const Text('Wszyscy'),
                      selected: _to == null,
                      onSelected: (_) => setState(() => _to = null)),
                  for (final p in widget.recipients)
                    ChoiceChip(
                        label: Text(p.name),
                        selected: _to == p.id,
                        onSelected: (_) => setState(() => _to = p.id)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                maxLength: messageMaxLength,
                maxLines: 4,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Wiadomość'),
                onChanged: (_) => setState(() {}),
              ),
              Text('Szybkie wiadomości', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in quickMessages)
                    ActionChip(
                      label: ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width - 96),
                        child: Text(q,
                            overflow: TextOverflow.ellipsis, maxLines: 2),
                      ),
                      onPressed: () => setState(() => _text.text = q),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _valid
                    ? () => Navigator.pop(context, (_to, _text.text.trim()))
                    : null,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder()),
                icon: const Icon(Icons.send_outlined),
                label: const Text('Wyślij'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
