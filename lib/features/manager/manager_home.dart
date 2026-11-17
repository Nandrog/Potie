import 'package:flutter/material.dart';

import '../../widgets/common.dart';
import '../../widgets/live_board.dart';
import 'alerts.dart';
import 'audit_tab.dart';
import 'day_tab.dart';
import 'reports_tab.dart';
import 'settings_tab.dart';
import 'team_tab.dart';

class ManagerHome extends StatefulWidget {
  const ManagerHome({super.key});
  @override
  State<ManagerHome> createState() => _ManagerHomeState();
}

class _ManagerHomeState extends State<ManagerHome> {
  int _i = 0;

  static const _titles = ['Day overview', 'Live timers', 'Audit trail', 'Team', 'Reports', 'Email setup'];
  static const _pages = <Widget>[
    DayTab(),
    LiveBoard(),
    AuditTab(),
    TeamTab(),
    ReportsTab(),
    SettingsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return RoleScaffold(
      title: _titles[_i],
      actions: const [NotifyButton(), AlertsButton()],
      body: IndexedStack(index: _i, children: _pages),
      bottomNav: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) => setState(() => _i = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Day'),
          NavigationDestination(icon: Icon(Icons.timer_outlined), label: 'Live'),
          NavigationDestination(icon: Icon(Icons.fact_check_outlined), label: 'Audit'),
          NavigationDestination(icon: Icon(Icons.groups_outlined), label: 'Team'),
          NavigationDestination(icon: Icon(Icons.picture_as_pdf_outlined), label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.mail_outline), label: 'Email'),
        ],
      ),
    );
  }
}
