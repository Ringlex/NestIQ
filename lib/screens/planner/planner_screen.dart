import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../household/household_controller.dart';
import 'calendar_tab.dart';
import 'messages_tab.dart';
import 'reminders_tab.dart';
import 'shopping_tab.dart';

enum PlannerTab { shopping, reminders, calendar, messages }

/// Planer domowy: zakupy, przypomnienia, kalendarz, wiadomości.
class PlannerScreen extends StatefulWidget {
  const PlannerScreen({
    super.key,
    required this.household,
    required this.account,
    this.initialTab = PlannerTab.shopping,
    this.tabRequest,
  });

  final HouseholdController household;
  final AccountController account;
  final PlannerTab initialTab;

  /// Prośba o przejście do zakładki (np. po dotknięciu powiadomienia).
  final ValueNotifier<PlannerTab?>? tabRequest;

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
      length: PlannerTab.values.length,
      vsync: this,
      initialIndex: widget.initialTab.index)
    ..addListener(_onTab);
  late final _messagesActive =
      ValueNotifier<bool>(widget.initialTab == PlannerTab.messages);

  void _onTab() =>
      _messagesActive.value = _tabs.index == PlannerTab.messages.index;

  @override
  void initState() {
    super.initState();
    widget.tabRequest?.addListener(_onRequest);
    // Po pierwszej klatce: odświeżanie powiadamia słuchaczy, a budowanie jeszcze trwa.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.household.refreshAll();
    });
  }

  void _onRequest() {
    final tab = widget.tabRequest?.value;
    if (tab == null) return;
    _tabs.animateTo(tab.index);
    widget.tabRequest!.value = null;
  }

  @override
  void dispose() {
    widget.tabRequest?.removeListener(_onRequest);
    _tabs.dispose();
    _messagesActive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.household;
    return ListenableBuilder(
      listenable: h,
      builder: (context, _) => Column(
        children: [
          TabBar(
            controller: _tabs,
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            labelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 13),
            tabs: [
              const Tab(child: _TabLabel('Zakupy')),
              const Tab(child: _TabLabel('Przypomnienia')),
              const Tab(child: _TabLabel('Kalendarz')),
              Tab(
                child: Badge(
                  isLabelVisible: h.unread > 0,
                  label: Text('${h.unread}'),
                  offset: const Offset(10, -6),
                  child: const _TabLabel('Wiadomości'),
                ),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                ShoppingTab(household: h, account: widget.account),
                RemindersTab(household: h, account: widget.account),
                CalendarTab(household: h, account: widget.account),
                MessagesTab(
                  household: h,
                  account: widget.account,
                  active: _messagesActive,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Etykieta zakładki w jednej linii, także przy dużej czcionce systemowej.
class _TabLabel extends StatelessWidget {
  const _TabLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.fade);
}
