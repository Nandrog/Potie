import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../features/print/print_service.dart';
import '../features/distributor/payments.dart' show PaymentNote;
import 'live_board.dart' show DueAlertHost;
import 'shell.dart';
import 'package:provider/provider.dart';

void toast(BuildContext c, String msg, {bool error = false}) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Brand.danger : null,
      behavior: SnackBarBehavior.floating,
    ));
}

/// Runs [job], shows any [BackendException] message. Returns null on failure.
Future<T?> guarded<T>(BuildContext c, Future<T> Function() job) async {
  try {
    return await job();
  } catch (e) {
    if (c.mounted) toast(c, e.toString(), error: true);
    return null;
  }
}

/// Rebuilds its child every second (for countdowns).
class Ticking extends StatefulWidget {
  const Ticking({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  late final Timer _t =
      Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class MethodPicker extends StatelessWidget {
  const MethodPicker({super.key, required this.value, required this.onChanged});
  final PayMethod value;
  final ValueChanged<PayMethod> onChanged;

  static const _icons = {
    PayMethod.mobileMoney: Icons.phone_android,
    PayMethod.cash: Icons.payments_outlined,
    PayMethod.visa: Icons.credit_card,
  };

  @override
  Widget build(BuildContext context) => SegmentedButton<PayMethod>(
        showSelectedIcon: false,
        segments: [
          for (final m in PayMethod.values)
            ButtonSegment(
              value: m,
              icon: Icon(_icons[m]),
              label: Text(m == PayMethod.mobileMoney ? 'MoMo' : m.label),
            ),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.token, {super.key});
  final PotToken token;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (token.status) {
      TokenStatus.issued => ('AWAITING POT', Colors.blueGrey),
      TokenStatus.out when token.overdue => ('OVERDUE', Brand.danger),
      TokenStatus.out => ('OUT', Brand.tealText(context)),
      TokenStatus.returned => ('RETURNED', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// Card summarising a token; shows a live countdown while the pot is out.
class TokenCard extends StatelessWidget {
  const TokenCard(this.t,
      {super.key,
      this.onTap,
      this.trailing,
      this.showWaiter = false,
      this.printable = true});
  final bool printable;
  final PotToken t;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showWaiter;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(t.potLabel ?? 'No pot',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const Spacer(),
                StatusChip(t),
                if (printable)
                  IconButton(
                    tooltip: 'Print token',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.print_outlined, size: 20),
                    onPressed: () => guarded(context, () => printTokenSlip(t)),
                  ),
              ]),
              const SizedBox(height: 8),
              Text(
                '${minutesLabel(t.totalMinutes)} · ${money(t.totalFees)} · ${t.paid ? t.method.label : 'Unpaid'}'
                '${showWaiter ? ' · ${t.waiterName}' : ''}',
              ),
              if (t.status == TokenStatus.out)
                Ticking(builder: (_) {
                  final r = t.remaining!;
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      r.isNegative
                          ? 'Over by ${countdown(r.abs())}'
                          : '${countdown(r)} left',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: r.isNegative
                            ? Brand.danger
                            : r.inMinutes < 5
                                ? Brand.amberText(context)
                                : Brand.tealText(context),
                      ),
                    ),
                  );
                }),
              PaymentNote(t),
              if (trailing != null) ...[const SizedBox(height: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Sun/moon icon that flips between light and dark.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: dark ? 'Switch to light mode' : 'Switch to dark mode',
      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      onPressed: () => context.read<ThemeController>().toggle(context),
    );
  }
}

/// The frame every signed-in screen uses: a menu button (side menu), the title
/// or - while searching - a search box, and an optional bottom bar.
/// Needs a [SearchQuery] provided above it.
class RoleScaffold extends StatelessWidget {
  const RoleScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.fab,
    this.bottomNav,
    this.drawerEntries = const [],
    this.searchable = false,
    this.searchHint,
  });
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? fab;
  final Widget? bottomNav;
  final List<DrawerEntry> drawerEntries;

  /// Show the search icon (the current screen has a list to filter).
  final bool searchable;
  final String? searchHint;

  @override
  Widget build(BuildContext context) {
    final q = context.watch<SearchQuery>();
    final searching = q.active && searchable;
    return Scaffold(
      appBar: AppBar(
        title: searching
            ? SearchField(query: q, hint: searchHint)
            : Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(2),
                    child: Image.asset('assets/images/arrows_bar_logo.png',
                        width: 32, height: 32),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
              ]),
        actions: searching
            ? [
                IconButton(
                    tooltip: 'Close search',
                    icon: const Icon(Icons.close),
                    onPressed: q.close),
              ]
            : [
                if (searchable)
                  IconButton(
                      tooltip: 'Search',
                      icon: const Icon(Icons.search),
                      onPressed: q.open),
                ...actions,
              ],
      ),
      drawer: AppDrawer(entries: drawerEntries),
      floatingActionButton: fab,
      bottomNavigationBar: bottomNav,
      body: DueAlertHost(child: body),
    );
  }
}
