import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../widgets/common.dart';
import '../../widgets/live_board.dart';
import '../../widgets/shell.dart';
import 'alerts.dart';
import 'audit_tab.dart';
import 'day_tab.dart';
import 'reports_tab.dart';
import 'settings_tab.dart';
import 'team_tab.dart';

/// Manager: four screens in the bottom bar; the rest live in the side menu.
class ManagerHome extends StatefulWidget {
  const ManagerHome({super.key});
  @override
  State<ManagerHome> createState() => _ManagerHomeState();
}

class _ManagerHomeState extends State<ManagerHome> {
  int _i = 0;
  final _search = SearchQuery();

  static const _titles = ['Day overview', 'Live timers', 'Team', 'Reports'];
  static const _hints = [
    'Search pots, waiters, payments',
    'Search pots or waiters',
    'Search team',
    ''
  ];
  static const _searchable = [true, true, true, false];
  static const _pages = <Widget>[DayTab(), LiveBoard(), TeamTab(), ReportsTab()];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _search,
      child: RoleScaffold(
        title: _titles[_i],
        searchable: _searchable[_i],
        searchHint: _hints[_i],
        actions: const [AlertsButton()],
        drawerEntries: [
          DrawerEntry(
              Icons.fact_check_outlined,
              'Audit trail',
              (c) => SubPage.open(c,
                  title: 'Audit trail',
                  child: const AuditTab(),
                  searchable: true,
                  hint: 'Search activity')),
          DrawerEntry(Icons.mail_outline, 'Email setup',
              (c) => SubPage.open(c, title: 'Email setup', child: const SettingsTab())),
        ],
        body: IndexedStack(index: _i, children: _pages),
        bottomNav: NavigationBar(
          selectedIndex: _i,
          onDestinationSelected: (v) {
            _search.reset();
            setState(() => _i = v);
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Day'),
            NavigationDestination(icon: Icon(Icons.timer_outlined), label: 'Live'),
            NavigationDestination(icon: Icon(Icons.groups_outlined), label: 'Team'),
            NavigationDestination(icon: Icon(Icons.picture_as_pdf_outlined), label: 'Reports'),
          ],
        ),
      ),
    );
  }
}
