import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/notifier.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../features/profile/profile_page.dart';
import 'live_board.dart' show enableTimeUpAlerts;
import 'update_dialog.dart';

/// The text typed in the app bar's search box. Screens that show a list watch
/// this and filter what they show; the bar shows the box when [active].
class SearchQuery extends ChangeNotifier {
  bool active = false;
  String text = '';

  void open() {
    active = true;
    notifyListeners();
  }

  void close() {
    active = false;
    text = '';
    notifyListeners();
  }

  void set(String v) {
    text = v;
    notifyListeners();
  }

  /// Forget any search (used when switching to another tab).
  void reset() {
    if (!active && text.isEmpty) return;
    close();
  }

  bool get filtering => text.trim().isNotEmpty;

  /// True when nothing is being searched, or any of [fields] contains the text.
  bool matches(Iterable<String?> fields) {
    if (!filtering) return true;
    final needle = text.trim().toLowerCase();
    return fields.any((f) => f != null && f.toLowerCase().contains(needle));
  }
}

/// Shown when a search hides every item.
class NoResults extends StatelessWidget {
  const NoResults(this.query, {super.key});
  final SearchQuery query;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text('Nothing matches “${query.text.trim()}”.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor)),
        ),
      );
}

/// One entry in the side menu (the screens that don't fit in the bottom bar).
class DrawerEntry {
  const DrawerEntry(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;

  /// Receives a context that stays valid after the menu has closed.
  final void Function(BuildContext context) onTap;
}

/// The side menu: the role's extra screens, then the things every user needs.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, this.entries = const []});
  final List<DrawerEntry> entries;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    // Close the menu, then act using the screen's own context (the menu's
    // context disappears once it has closed).
    final scaffold = Scaffold.of(context);
    void run(void Function(BuildContext) action) {
      final host = scaffold.context;
      scaffold.closeDrawer();
      action(host);
    }

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              color: scheme.primary.withValues(alpha: .08),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(6),
                    child: Image.asset('assets/images/arrows_bar_logo.png',
                        width: 56, height: 56),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w800)),
                      Text(user.role.label,
                          style: TextStyle(color: Theme.of(context).hintColor)),
                    ],
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            for (final e in entries)
              ListTile(
                leading: Icon(e.icon),
                title: Text(e.label),
                onTap: () => run(e.onTap),
              ),
            if (entries.isNotEmpty) const Divider(),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Profile & settings'),
              onTap: () => run((c) => Navigator.of(c).push(
                  MaterialPageRoute<void>(builder: (_) => const ProfilePage()))),
            ),
            SwitchListTile(
              secondary: Icon(dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
              title: const Text('Dark mode'),
              value: dark,
              onChanged: (_) => context.read<ThemeController>().toggle(context),
            ),
            if (TimeUpNotifier.supported)
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Time-up alerts'),
                subtitle: const Text('Allow notifications'),
                onTap: () => run(enableTimeUpAlerts),
              ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('Check for updates'),
              onTap: () => run((c) => checkForUpdates(c)),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () => run((_) => session.signOut()),
            ),
          ],
        ),
      ),
    );
  }
}

/// A screen opened from the side menu (with a back button, and optional search).
class SubPage extends StatelessWidget {
  const SubPage({super.key, required this.title, required this.child, this.searchable = false, this.hint});
  final String title;
  final Widget child;
  final bool searchable;
  final String? hint;

  /// Opens [child] as its own screen.
  static Future<void> open(BuildContext context,
          {required String title, required Widget child, bool searchable = false, String? hint}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SubPage(title: title, searchable: searchable, hint: hint, child: child)));

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (_) => SearchQuery(),
        child: _SubScaffold(title: title, searchable: searchable, hint: hint, child: child),
      );
}

class _SubScaffold extends StatelessWidget {
  const _SubScaffold({required this.title, required this.child, required this.searchable, this.hint});
  final String title;
  final Widget child;
  final bool searchable;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final q = context.watch<SearchQuery>();
    return Scaffold(
      appBar: AppBar(
        title: q.active ? SearchField(query: q, hint: hint) : Text(title),
        actions: [
          if (searchable)
            IconButton(
              tooltip: q.active ? 'Close search' : 'Search',
              icon: Icon(q.active ? Icons.close : Icons.search),
              onPressed: q.active ? q.close : q.open,
            ),
        ],
      ),
      body: child,
    );
  }
}

/// The text box that replaces the title while searching.
class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.query, this.hint});
  final SearchQuery query;
  final String? hint;
  @override
  Widget build(BuildContext context) => TextField(
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: query.set,
        style: Theme.of(context).textTheme.titleMedium,
        cursorColor: Theme.of(context).colorScheme.primary,
        decoration: InputDecoration.collapsed(hintText: hint ?? 'Search'),
      );
}
