import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../account/account_models.dart';
import '../../household/household_controller.dart';
import '../../household/household_models.dart';
import '../../widgets/motion.dart';
import 'planner_common.dart';
import '../../widgets/responsive.dart';

/// Zakładka „Zakupy”: listy zakupów, także współdzielone z innymi profilami.
class ShoppingTab extends StatelessWidget {
  const ShoppingTab(
      {super.key, required this.household, required this.account});

  final HouseholdController household;
  final AccountController account;

  Future<void> _create(BuildContext context) async {
    final result = await showDialog<({String name})>(
      context: context,
      builder: (_) => const _NewListDialog(),
    );
    if (result == null || !context.mounted) return;
    await guarded(context, () => household.createList(result.name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ProfileNames.of(account);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _create(context),
        icon: const Icon(Icons.add),
        label: const Text('Nowa lista'),
      ),
      body: RefreshIndicator(
        onRefresh: household.refreshLists,
        child: household.lists.isEmpty
            ? ListView(children: const [
                SizedBox(height: 80),
                PlannerEmpty(
                  icon: Icons.shopping_cart_outlined,
                  title: 'Nie masz jeszcze list zakupów',
                  message:
                      'Dodaj listę, wpisuj na nią produkty i udostępnij ją domownikom. '
                      'Kto jest w sklepie, odhacza to, co kupił.',
                ),
              ])
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  ResponsiveColumns(
                    minColumnWidth: 420,
                    children: [
                      for (var i = 0; i < household.lists.length; i++)
                        FadeUp(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _ListCard(
                              list: household.lists[i],
                              mine: household.lists[i].ownerProfileId ==
                                  account.active?.id,
                              names: names,
                              onTap: () => Navigator.of(context).push(AppRoute(
                                builder: (_) => ShoppingListScreen(
                                  household: household,
                                  account: account,
                                  listId: household.lists[i].id,
                                ),
                              )),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (household.error != null)
                    Text(household.error!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error)),
                ],
              ),
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard(
      {required this.list,
      required this.mine,
      required this.names,
      required this.onTap});

  final PlannerList list;
  final bool mine;
  final ProfileNames names;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sharedProfiles = [for (final id in list.sharedWith) names.profile(id)]
        .whereType<Profile>()
        .toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14)),
                child: Icon(Icons.shopping_cart_outlined,
                    color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(list.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      list.items.isEmpty
                          ? 'Pusta'
                          : list.openCount == 0
                              ? 'Wszystko kupione'
                              : 'Do kupienia: ${list.openCount}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (!mine)
                      Text('Od: ${names.of(list.ownerProfileId)}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (sharedProfiles.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final p in sharedProfiles.take(3))
                      Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: ProfileAvatar(profile: p, size: 24)),
                  ],
                ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewListDialog extends StatefulWidget {
  const _NewListDialog();

  @override
  State<_NewListDialog> createState() => _NewListDialogState();
}

class _NewListDialogState extends State<_NewListDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nowa lista zakupów'),
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 60,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
            labelText: 'Nazwa',
            hintText: 'np. Spożywcze, Apteka',
            counterText: ''),
        onChanged: (_) => setState(() {}),
        onSubmitted: (v) =>
            v.trim().isEmpty ? null : Navigator.pop(context, (name: v.trim())),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Anuluj')),
        FilledButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (name: _name.text.trim())),
          child: const Text('Utwórz'),
        ),
      ],
    );
  }
}

/// Jedna lista: dodawanie, odhaczanie i udostępnianie.
class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen(
      {super.key,
      required this.household,
      required this.account,
      required this.listId});

  final HouseholdController household;
  final AccountController account;
  final String listId;

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen> {
  final _text = TextEditingController();
  final _quantity = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _quantity.dispose();
    _focus.dispose();
    super.dispose();
  }

  PlannerList? get _list =>
      widget.household.lists.where((l) => l.id == widget.listId).firstOrNull;

  Future<void> _add() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final quantity = _quantity.text.trim();
    _text.clear();
    _quantity.clear();
    _focus.requestFocus();
    await guarded(
        context,
        () =>
            widget.household.addItem(widget.listId, text, quantity: quantity));
  }

  Future<void> _share(PlannerList list) async {
    final others = widget.account.profiles
        .where((p) => p.id != list.ownerProfileId)
        .toList();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ShareSheet(profiles: others, selected: list.sharedWith),
    );
    if (result == null || !mounted) return;
    await guarded(context,
        () => widget.household.updateList(list.id, sharedWith: result));
  }

  Future<void> _rename(PlannerList list) async {
    final controller = TextEditingController(text: list.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Zmień nazwę'),
        content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(counterText: '')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Zapisz')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await guarded(
        context, () => widget.household.updateList(list.id, name: name));
  }

  Future<void> _delete(PlannerList list) async {
    if (!await confirmDialog(context, 'Usunąć listę „${list.name}”?',
        'Znikną także pozycje i udostępnienie.', 'Usuń')) {
      return;
    }
    if (!mounted) return;
    if (await guarded(context, () => widget.household.deleteList(list.id)) &&
        mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.household,
      builder: (context, _) {
        final list = _list;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        if (list == null) {
          return Scaffold(
              appBar: AppBar(),
              body: const PlannerEmpty(
                  icon: Icons.search_off,
                  title: 'Lista nie istnieje',
                  message:
                      'Mogła zostać usunięta albo przestała być udostępniana.'));
        }
        final mine = list.ownerProfileId == widget.account.active?.id;
        final names = ProfileNames.of(widget.account);
        final open = [
          for (final i in list.items)
            if (!i.checked) i
        ];
        final done = [
          for (final i in list.items)
            if (i.checked) i
        ];

        Widget tile(PlannerItem item) => Dismissible(
              key: ValueKey(item.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: scheme.errorContainer,
                child:
                    Icon(Icons.delete_outline, color: scheme.onErrorContainer),
              ),
              onDismissed: (_) => guarded(
                  context, () => widget.household.deleteItem(list.id, item.id)),
              child: CheckboxListTile(
                value: item.checked,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) => guarded(
                    context,
                    () => widget.household
                        .setItemChecked(list.id, item.id, v ?? false)),
                title: Text(
                  item.quantity == null
                      ? item.text
                      : '${item.text} · ${item.quantity}',
                  style: item.checked
                      ? theme.textTheme.bodyLarge?.copyWith(
                          decoration: TextDecoration.lineThrough,
                          color: scheme.onSurfaceVariant)
                      : theme.textTheme.bodyLarge,
                ),
                subtitle: item.checked && item.checkedBy != null
                    ? Text('Kupił(a): ${names.of(item.checkedBy)}')
                    : null,
              ),
            );

        return Scaffold(
          appBar: AppBar(
            title: Text(list.name),
            actions: [
              if (mine)
                IconButton(
                  tooltip: 'Udostępnij',
                  onPressed: () => _share(list),
                  icon: Badge(
                    isLabelVisible: list.sharedWith.isNotEmpty,
                    label: Text('${list.sharedWith.length}'),
                    child: const Icon(Icons.group_add_outlined),
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: 'Więcej',
                onSelected: (a) {
                  switch (a) {
                    case 'clear':
                      guarded(context,
                          () => widget.household.clearChecked(list.id));
                    case 'rename':
                      _rename(list);
                    case 'delete':
                      _delete(list);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'clear',
                      enabled: done.isNotEmpty,
                      child: const Text('Usuń kupione')),
                  if (mine)
                    const PopupMenuItem(
                        value: 'rename', child: Text('Zmień nazwę')),
                  if (mine)
                    const PopupMenuItem(
                        value: 'delete', child: Text('Usuń listę')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (!mine || list.sharedWith.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      mine
                          ? 'Udostępniona: ${list.sharedWith.map(names.of).join(', ')}'
                          : 'Udostępnia: ${names.of(list.ownerProfileId)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        maxLength: 100,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _add(),
                        decoration: const InputDecoration(
                            hintText: 'Dodaj produkt', counterText: ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _quantity,
                        maxLength: 30,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _add(),
                        decoration: const InputDecoration(
                            hintText: 'Ilość', counterText: ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                        onPressed: _add,
                        tooltip: 'Dodaj',
                        icon: const Icon(Icons.add)),
                  ],
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: widget.household.refreshLists,
                  child: list.items.isEmpty
                      ? ListView(children: const [
                          SizedBox(height: 40),
                          PlannerEmpty(
                              icon: Icons.add_shopping_cart,
                              title: 'Lista jest pusta',
                              message: 'Wpisz pierwszy produkt powyżej.'),
                        ])
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 32),
                          children: [
                            for (final i in open) tile(i),
                            if (done.isNotEmpty) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 16, 16, 4),
                                child: Text('Kupione (${done.length})',
                                    style: theme.textTheme.titleSmall),
                              ),
                              for (final i in done) tile(i),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.profiles, required this.selected});

  final List<Profile> profiles;
  final List<String> selected;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  late final Set<String> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Udostępnij listę', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
                'Wybrane profile zobaczą listę i będą mogły dopisywać oraz odhaczać produkty.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (widget.profiles.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('W domu nie ma innych profili.'))
            else
              for (final p in widget.profiles)
                CheckboxListTile(
                  secondary: ProfileAvatar(profile: p, size: 36),
                  title: Text(p.name),
                  value: _selected.contains(p.id),
                  onChanged: (v) => setState(() =>
                      v == true ? _selected.add(p.id) : _selected.remove(p.id)),
                ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.pop(context, _selected.toList()),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  shape: const StadiumBorder()),
              child: const Text('Zapisz'),
            ),
          ],
        ),
      ),
    );
  }
}
