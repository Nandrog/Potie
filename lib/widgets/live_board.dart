import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/live_tokens.dart';
import '../core/models.dart';
import '../core/notifier.dart';
import '../core/theme.dart';
import '../features/distributor/payments.dart' show PaymentNote;
import 'common.dart';

/// Live view of every pot that is out: a progress bar per pot that fills as
/// its time runs down, sorted so the pot closest to (or past) its time is first.
/// [actions] adds per-pot buttons (the distributor's Extend / Returned).
class LiveBoard extends StatelessWidget {
  const LiveBoard({super.key, this.actions});
  final Widget Function(BuildContext context, PotToken t, Future<void> Function() reload)? actions;

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveTokens>();
    if (!live.loaded) {
      return Center(
          child: live.error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(live.error!, textAlign: TextAlign.center))
              : const CircularProgressIndicator());
    }
    final list = live.tokens;
    return RefreshIndicator(
      onRefresh: live.refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Ticking(builder: (_) => _Summary(list)),
          const SizedBox(height: 4),
          if (live.updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Icon(Icons.circle, size: 9, color: Brand.tealText(context)),
                const SizedBox(width: 6),
                Text('Live · updated ${hm(live.updatedAt!)}',
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).hintColor)),
              ]),
            ),
          if (list.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 120),
              child: Center(child: Text('No pots are out.')),
            )
          else
            for (final t in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _LiveCard(
                  t,
                  trailing: actions?.call(context, t, live.refresh),
                ),
              ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary(this.list);
  final List<PotToken> list;
  @override
  Widget build(BuildContext context) {
    final over = list.where((t) => t.overdue).length;
    final soon = list
        .where((t) => !t.overdue && t.remaining!.inMinutes < 5)
        .length;
    Widget box(String label, int n, Color c) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(children: [
                Text('$n',
                    style: TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w800, color: c)),
                Text(label, style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        );
    return Row(children: [
      box('Out', list.length, Brand.tealText(context)),
      box('Under 5 min', soon, Brand.amberText(context)),
      box('Time up', over, Brand.danger),
    ]);
  }
}

class _LiveCard extends StatelessWidget {
  const _LiveCard(this.t, {this.trailing});
  final PotToken t;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Ticking(builder: (_) {
          final r = t.remaining ?? Duration.zero;
          final total = Duration(minutes: t.totalMinutes);
          final used = total - r; // may exceed total when overdue
          final frac = total.inSeconds == 0
              ? 1.0
              : (used.inSeconds / total.inSeconds).clamp(0.0, 1.0);
          final color = r.isNegative
              ? Brand.danger
              : r.inMinutes < 5
                  ? Brand.amberText(context)
                  : Brand.tealText(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(t.potLabel ?? 'Pot',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(t.waiterName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Theme.of(context).hintColor))),
                StatusChip(t),
              ]),
              const SizedBox(height: 10),
              Text(
                r.isNegative
                    ? 'Over by ${countdown(r.abs())}'
                    : '${countdown(r)} left',
                style: TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w800, color: color),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: frac,
                  minHeight: 10,
                  color: color,
                  backgroundColor: color.withValues(alpha: .15),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Out ${hm(t.clearedAt!)} · due ${hm(t.dueAt!)} · '
                '${minutesLabel(t.totalMinutes)}'
                '${t.extensions.isEmpty ? '' : ' (+${t.extensions.length} ext.)'}',
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor),
              ),
              PaymentNote(t),
              if (trailing != null) ...[const SizedBox(height: 12), trailing!],
            ],
          );
        }),
      ),
    );
  }
}

/// Wraps a screen: when a pot's time runs out, plays a sound and shows a
/// banner naming the pot and waiter (system notifications cover the case where
/// the app is in the background).
class DueAlertHost extends StatefulWidget {
  const DueAlertHost({super.key, required this.child});
  final Widget child;
  @override
  State<DueAlertHost> createState() => _DueAlertHostState();
}

class _DueAlertHostState extends State<DueAlertHost> {
  StreamSubscription<PotToken>? _sub;
  LiveTokens? _live;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final live = context.read<LiveTokens>();
    if (!identical(live, _live)) {
      _sub?.cancel();
      _live = live;
      _sub = live.dueEvents.listen(_onDue);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onDue(PotToken t) {
    if (!mounted) return;
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentMaterialBanner();
    m.showMaterialBanner(MaterialBanner(
      backgroundColor: Brand.danger.withValues(alpha: .15),
      leading: const Icon(Icons.alarm, color: Brand.danger),
      content: Text(
        'Time is up: ${t.potLabel} (${t.waiterName}). Tell them to bring the pot back.',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      actions: [
        TextButton(onPressed: m.hideCurrentMaterialBanner, child: const Text('OK')),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Bell that turns on time-up notifications (the browser only allows this
/// from a button press).
class NotifyButton extends StatelessWidget {
  const NotifyButton({super.key});
  @override
  Widget build(BuildContext context) {
    final n = context.read<LiveTokens>().notifier;
    if (n == null || !TimeUpNotifier.supported) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Turn on time-up alerts',
      icon: const Icon(Icons.notifications_active_outlined),
      onPressed: () async {
        final ok = await n.requestPermission();
        if (context.mounted) {
          toast(
              context,
              ok
                  ? 'Time-up alerts are on.'
                  : 'Alerts are blocked. Allow notifications for this app in settings.',
              error: !ok);
        }
      },
    );
  }
}
