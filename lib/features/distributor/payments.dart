import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/shell.dart';

/// Asks how an unpaid token was paid and records it. Returns the updated token
/// (null if cancelled or it failed).
Future<PotToken?> collectPayment(BuildContext context, PotToken t) async {
  final method = await showDialog<PayMethod>(
    context: context,
    builder: (_) => _CollectDialog(t),
  );
  if (method == null || !context.mounted) return null;
  final b = context.read<Session>().backend;
  final r = await guarded(context, () => b.settlePayment(t.id, method));
  if (r != null && context.mounted) {
    toast(context, '${money(t.amount)} received from ${t.waiterName}.');
  }
  return r;
}

class _CollectDialog extends StatefulWidget {
  const _CollectDialog(this.t);
  final PotToken t;
  @override
  State<_CollectDialog> createState() => _CollectDialogState();
}

class _CollectDialogState extends State<_CollectDialog> {
  PayMethod _method = PayMethod.mobileMoney;
  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return AlertDialog(
      title: Text('Collect payment · ${t.potLabel}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.waiterName),
        const SizedBox(height: 6),
        Text(money(t.amount),
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
        if (t.paymentOverdue)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Past the 12 hour limit',
                style: TextStyle(color: Brand.danger)),
          ),
        const SizedBox(height: 14),
        MethodPicker(value: _method, onChanged: (m) => setState(() => _method = m)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(120, 40)),
          onPressed: () => Navigator.pop(context, _method),
          child: const Text('Payment received'),
        ),
      ],
    );
  }
}

/// Small line showing that a token is unpaid and by when it must be paid.
class PaymentNote extends StatelessWidget {
  const PaymentNote(this.t, {super.key});
  final PotToken t;
  @override
  Widget build(BuildContext context) {
    if (t.paid) return const SizedBox.shrink();
    return Ticking(builder: (_) {
      final left = t.payDueAt?.difference(DateTime.now());
      final over = left != null && left.isNegative;
      final color = over ? Brand.danger : Brand.amberText(context);
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Icon(Icons.payments_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              over
                  ? 'UNPAID · ${money(t.amount)} · ${countdown(left.abs())} past the 12 h limit'
                  : 'UNPAID · ${money(t.amount)} · ${t.payTiming.label.toLowerCase()}'
                      '${left == null ? '' : ' · ${countdown(left)} left'}',
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
      );
    });
  }
}

/// What to do when a pot with an unpaid token comes back.
typedef ReturnChoice = ({bool returned, PayMethod? paidBy});

Future<ReturnChoice?> askReturn(BuildContext context, PotToken t) =>
    showDialog<ReturnChoice>(context: context, builder: (_) => _ReturnDialog(t));

class _ReturnDialog extends StatefulWidget {
  const _ReturnDialog(this.t);
  final PotToken t;
  @override
  State<_ReturnDialog> createState() => _ReturnDialogState();
}

class _ReturnDialogState extends State<_ReturnDialog> {
  PayMethod _method = PayMethod.mobileMoney;
  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return AlertDialog(
      title: Text('${t.waiterName} returned ${t.potLabel}?'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (t.paid)
          const Text('It will be recorded as returned.')
        else ...[
          Text('${money(t.amount)} is still unpaid (${t.payTiming.label.toLowerCase()}).'),
          const SizedBox(height: 12),
          MethodPicker(value: _method, onChanged: (m) => setState(() => _method = m)),
        ],
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        if (!t.paid)
          TextButton(
            onPressed: () => Navigator.pop(context, (returned: true, paidBy: null)),
            child: const Text('Return, pay later'),
          ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(100, 40)),
          onPressed: () => Navigator.pop(
              context, (returned: true, paidBy: t.paid ? null : _method)),
          child: Text(t.paid ? 'Returned' : 'Paid & returned'),
        ),
      ],
    );
  }
}

/// Tokens that still have to be paid, earliest deadline first.
class UnpaidTab extends StatefulWidget {
  const UnpaidTab({super.key});
  @override
  State<UnpaidTab> createState() => _UnpaidTabState();
}

class _UnpaidTabState extends State<UnpaidTab> {
  List<PotToken>? _list;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final l = await guarded(context, b.unpaidTokens);
    if (l != null && mounted) setState(() => _list = l);
  }

  @override
  Widget build(BuildContext context) {
    final all = _list;
    if (all == null) return const Center(child: CircularProgressIndicator());
    final q = context.watch<SearchQuery>();
    final list = all
        .where((t) => q.matches([t.potLabel, t.waiterName, t.payTiming.label]))
        .toList();
    final total = list.fold(0.0, (s, t) => s + t.amount);
    return RefreshIndicator(
      onRefresh: _load,
      child: list.isEmpty
          ? ListView(children: [
              const SizedBox(height: 160),
              Center(
                  child: all.isNotEmpty
                      ? NoResults(q)
                      : const Text('Nothing is waiting for payment.')),
            ])
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.hourglass_bottom),
                    title: Text('${list.length} unpaid · ${money(total)}'),
                    subtitle: const Text('Each must be paid within 12 hours of the pot going out.'),
                  ),
                ),
                const SizedBox(height: 8),
                for (final t in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Text(t.potLabel ?? 'Pot',
                                  style: const TextStyle(
                                      fontSize: 20, fontWeight: FontWeight.w800)),
                              const SizedBox(width: 10),
                              Expanded(
                                  child: Text(t.waiterName,
                                      style: TextStyle(
                                          color: Theme.of(context).hintColor))),
                              StatusChip(t),
                            ]),
                            const SizedBox(height: 4),
                            Text('Out ${dateTime(t.clearedAt ?? t.issuedAt)}'
                                '${t.returnedAt == null ? '' : ' · back ${hm(t.returnedAt!)}'}'),
                            PaymentNote(t),
                            const SizedBox(height: 10),
                            FilledButton.icon(
                              onPressed: () async {
                                final r = await collectPayment(context, t);
                                if (r != null) _load();
                              },
                              icon: const Icon(Icons.payments_outlined),
                              label: const Text('Collect payment'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
