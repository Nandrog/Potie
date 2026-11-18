import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potie/core/live_tokens.dart';
import 'package:potie/core/session.dart';
import 'package:potie/core/theme.dart';
import 'package:potie/features/distributor/distributor_home.dart';
import 'package:potie/features/manager/manager_home.dart';
import 'package:potie/widgets/shell.dart';
import 'package:provider/provider.dart';

import 'support/demo_backend.dart';

/// Pumps [home] for a signed-in demo user.
Future<void> open(WidgetTester t, String email, String password, Widget home) async {
  await t.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  late Session session;
  late LiveTokens live;
  await t.runAsync(() async {
    final b = DemoBackend();
    await b.signIn(email, password);
    session = Session(b);
    await session.restore();
    live = LiveTokens(b);
    await live.refresh();
  });
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: session),
      ChangeNotifierProvider.value(value: ThemeController(ThemeMode.light)),
      ChangeNotifierProvider.value(value: live),
    ],
    child: MaterialApp(theme: Brand.theme(Brightness.light), home: home),
  ));
  await t.pump(const Duration(milliseconds: 300));
}

Finder inBottomBar(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Future<void> openMenu(WidgetTester t) async {
  await t.tap(find.byTooltip('Open navigation menu'));
  await t.pump(); // start the slide-in
  await t.pump(const Duration(milliseconds: 600)); // let it finish
}

void main() {
  testWidgets('manager: four icons at the bottom, everything else in the menu', (t) async {
    await open(t, 'manager@potie.app', 'Manager@123', const ManagerHome());

    expect(find.byType(NavigationDestination), findsNWidgets(4));
    for (final l in ['Day', 'Live', 'Team', 'Reports']) {
      expect(inBottomBar(l), findsOneWidget, reason: l);
    }
    expect(inBottomBar('Audit'), findsNothing);
    expect(inBottomBar('Email'), findsNothing);

    await openMenu(t);
    for (final l in [
      'Audit trail',
      'Email setup',
      'Profile & settings',
      'Dark mode',
      'Check for updates',
      'Sign out',
    ]) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    expect(find.text('Maria Manager'), findsOneWidget); // who is signed in
  });

  testWidgets('manager: a menu item opens its own screen with a back button', (t) async {
    await open(t, 'manager@potie.app', 'Manager@123', const ManagerHome());
    await openMenu(t);
    await t.tap(find.text('Audit trail'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));

    expect(find.byType(SubPage), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget); // audit is searchable

    await t.tap(find.byType(BackButton));
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    expect(find.byType(SubPage), findsNothing);
  });

  testWidgets('manager: search filters the team list', (t) async {
    await open(t, 'manager@potie.app', 'Manager@123', const ManagerHome());
    await t.tap(inBottomBar('Team'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Maria Manager'), findsOneWidget);

    await t.tap(find.byIcon(Icons.search));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(SearchField), findsOneWidget);

    await t.enterText(find.descendant(of: find.byType(SearchField), matching: find.byType(TextField)), 'distri');
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Derrick Distributor'), findsOneWidget);
    expect(find.text('Maria Manager'), findsNothing);

    // Closing the search brings everyone back.
    await t.tap(find.byIcon(Icons.close));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(SearchField), findsNothing);
    expect(find.text('Maria Manager'), findsOneWidget);
    expect(find.text('Derrick Distributor'), findsOneWidget);
  });

  testWidgets('manager: switching tabs clears the search; Reports has no search', (t) async {
    await open(t, 'manager@potie.app', 'Manager@123', const ManagerHome());
    await t.tap(inBottomBar('Team'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byIcon(Icons.search));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.descendant(of: find.byType(SearchField), matching: find.byType(TextField)), 'zzz');
    await t.pump(const Duration(milliseconds: 300));

    await t.tap(inBottomBar('Reports'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(SearchField), findsNothing);
    expect(find.byIcon(Icons.search), findsNothing);

    await t.tap(inBottomBar('Team'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Maria Manager'), findsOneWidget); // old search is gone
  });

  testWidgets('manager: Live search narrows the pots out', (t) async {
    await open(t, 'manager@potie.app', 'Manager@123', const ManagerHome());
    await t.tap(inBottomBar('Live'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Wanda Waiter'), findsOneWidget); // the demo pot that is out

    await t.tap(find.byIcon(Icons.search));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.descendant(of: find.byType(SearchField), matching: find.byType(TextField)), 'nobody');
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Wanda Waiter'), findsNothing);
    expect(find.textContaining('Nothing matches'), findsOneWidget);
  });

  testWidgets('distributor: four icons at the bottom; Pots and Printer in the menu', (t) async {
    await open(t, 'distributor@potie.app', 'Distro@123', const DistributorHome());

    expect(find.byType(NavigationDestination), findsNWidgets(4));
    for (final l in ['Issue', 'Live', 'Unpaid', 'Waiters']) {
      expect(inBottomBar(l), findsOneWidget, reason: l);
    }
    await openMenu(t);
    for (final l in ['Pots', 'Printer', 'Profile & settings', 'Sign out']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
  });
}
