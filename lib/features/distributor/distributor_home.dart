import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/live_board.dart';
import '../print/print_service.dart';
import '../print/printer_setup.dart';
import 'payments.dart';
import 'pots_tab.dart';
import 'waiters_tab.dart';

/// The distributor runs the whole floor: registers waiters, issues tokens to
/// them, extends time and records pots as returned. Waiters never sign in.
class DistributorHome extends StatelessWidget {
  const DistributorHome({super.key});
  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 5,
      child: RoleScaffold(
        title: 'Distributor',
        actions: [NotifyButton(), PrinterButton()],
        bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
          Tab(icon: Icon(Icons.add_circle_outline), text: 'Issue token'),
          Tab(icon: Icon(Icons.timer_outlined), text: 'Live'),
          Tab(icon: Icon(Icons.hourglass_bottom), text: 'Unpaid'),
          Tab(icon: Icon(Icons.badge_outlined), text: 'Waiters'),
          Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Pots'),
        ]),
        body: TabBarView(
            children: [_IssueTab(), _OutTab(), UnpaidTab(), WaitersTab(), PotsTab()]),
      ),
    );
  }
}

class _IssueTab extends StatefulWidget {
  const _IssueTab();
  @override
  State<_IssueTab> createState() => _IssueTabState();
}

class _IssueTabState extends State<_IssueTab> {
  List<Pot> _pots = [];
  List<Waiter> _waiters = [];
  bool _loading = true;
  String? _potId;
  String? _waiterId;
  int _minutes = 60;
  final _custom = TextEditingController();
  final _amount = TextEditingController();
  PayMethod _method = PayMethod.mobileMoney;
  PayTiming _timing = PayTiming.immediate;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _custom.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final pots = await guarded(context, b.availablePots);
    if (!mounted) return;
    final waiters = await guarded(context, b.waiters);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _pots = pots ?? _pots;
      _waiters = waiters ?? _waiters;
      if (!_pots.any((p) => p.id == _potId)) {
        _potId = _pots.isEmpty ? null : _pots.first.id;
      }
      if (!_waiters.any((w) => w.id == _waiterId)) _waiterId = null;
    });
  }

  Future<void> _issue() async {
    final amount = double.tryParse(_amount.text.replaceAll(',', ''));
    final minutes = _custom.text.isNotEmpty ? int.tryParse(_custom.text) : _minutes;
    if (_waiterId == null || _potId == null) {
      toast(context, 'Choose a waiter and a pot.', error: true);
      return;
    }
    if (amount == null || amount <= 0 || minutes == null || minutes <= 0) {
      toast(context, 'Enter a valid time and amount.', error: true);
      return;
    }
    setState(() => _busy = true);
    final b = context.read<Session>().backend;
    final t = await guarded(
        context,
        () => b.issueToken(
            waiterId: _waiterId!,
            potId: _potId!,
            minutes: minutes,
            amount: amount,
            method: _method,
            timing: _timing));
    if (!mounted) return;
    setState(() => _busy = false);
    if (t == null) {
      _load(); // e.g. the pot was taken meanwhile
      return;
    }
    setState(() {
      _amount.clear();
      _custom.clear();
      _waiterId = null;
    });
    _load();
    await showDialog<void>(context: context, builder: (_) => _TokenIssuedDialog(t));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final noWaiters = _waiters.isEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (noWaiters)
            _warn(context,
                'No waiters yet. Register them in the Waiters tab first.'),
          if (_pots.isEmpty)
            _warn(context,
                'No pots are available. Register pots (or wait for one to be returned) in the Pots tab.'),
          DropdownButtonFormField<String>(
            initialValue: _waiterId,
            decoration: const InputDecoration(labelText: 'Waiter'),
            items: [
              for (final w in _waiters)
                DropdownMenuItem(value: w.id, child: Text(w.name))
            ],
            onChanged: (v) => setState(() => _waiterId = v),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _potId,
            decoration: const InputDecoration(labelText: 'Pot'),
            items: [
              for (final p in _pots)
                DropdownMenuItem(value: p.id, child: Text(p.label))
            ],
            onChanged: (v) => setState(() => _potId = v),
          ),
          const SizedBox(height: 18),
          const Text('Time out'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final m in const [30, 45, 60, 90, 120])
              ChoiceChip(
                label: Text(minutesLabel(m)),
                selected: _custom.text.isEmpty && _minutes == m,
                onSelected: (_) => setState(() {
                  _minutes = m;
                  _custom.clear();
                }),
              ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _custom,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Or custom minutes'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _amount,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: _timing == PayTiming.immediate
                    ? 'Amount received'
                    : 'Amount to be paid'),
          ),
          const SizedBox(height: 18),
          const Text('Payment'),
          const SizedBox(height: 8),
          SegmentedButton<PayTiming>(
            showSelectedIcon: false,
            segments: [
              for (final p in PayTiming.values)
                ButtonSegment(value: p, label: Text(p.label)),
            ],
            selected: {_timing},
            onSelectionChanged: (s) => setState(() => _timing = s.first),
          ),
          const SizedBox(height: 12),
          if (_timing == PayTiming.immediate) ...[
            const Text('Received by'),
            const SizedBox(height: 8),
            MethodPicker(value: _method, onChanged: (m) => setState(() => _method = m)),
          ] else
            Text(
              _timing == PayTiming.onReturn
                  ? 'Collect the payment when the waiter brings the pot back, and not later than 12 hours after it goes out.'
                  : 'The waiter can pay later, but not more than 12 hours after the pot goes out. It shows under Unpaid until collected.',
              style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy || noWaiters || _pots.isEmpty ? null : _issue,
            icon: const Icon(Icons.outbox),
            label: const Text('Issue pot & generate token'),
          ),
        ],
      ),
    );
  }

  Widget _warn(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(text,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ),
      );
}

/// Shown after a token is issued: the number, and a print button.
class _TokenIssuedDialog extends StatelessWidget {
  const _TokenIssuedDialog(this.t);
  final PotToken t;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${t.potLabel} to ${t.waiterName}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.potLabel ?? '',
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('${minutesLabel(t.minutes)} · ${money(t.amount)} · '
              '${t.paid ? t.method.label : 'UNPAID, ${t.payTiming.label.toLowerCase()}'}'),
          const SizedBox(height: 4),
          const Text('Timer started. The token number is on the printed slip.'),
        ]),
        actions: [
          FilledButton.icon(
            onPressed: () => guarded(context, () => printTokenSlip(t)),
            icon: const Icon(Icons.print_outlined),
            label: const Text('Print token'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
}

/// Live board of pots that are out, with the distributor's Extend / Returned buttons.
class _OutTab extends StatelessWidget {
  const _OutTab();

  Future<void> _return(BuildContext context, PotToken t, Future<void> Function() reload) async {
    final choice = await askReturn(context, t);
    if (choice == null || !context.mounted) return;
    final b = context.read<Session>().backend;
    if (choice.paidBy != null) {
      final paid = await guarded(context, () => b.settlePayment(t.id, choice.paidBy!));
      if (paid == null) return reload();
    }
    if (!context.mounted) return;
    final r = await guarded(context, () => b.returnPot(t.id));
    if (r != null && context.mounted) {
      toast(context, '${t.potLabel} recorded as returned.');
    }
    await reload();
  }

  Future<void> _extend(BuildContext context, PotToken t, Future<void> Function() reload) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ExtendSheet(t),
    );
    if (ok == true) {
      await reload();
      if (context.mounted) toast(context, 'Time extended.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiveBoard(
      actions: (context, t, reload) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!t.paid)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.icon(
                onPressed: () async {
                  if (await collectPayment(context, t) != null) await reload();
                },
                icon: const Icon(Icons.payments_outlined),
                label: Text('Collect ${money(t.amount)}'),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _extend(context, t, reload),
                  icon: const Icon(Icons.more_time),
                  label: const Text('Extend'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _return(context, t, reload),
                  icon: const Icon(Icons.assignment_return_outlined),
                  label: const Text('Returned'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExtendSheet extends StatefulWidget {
  const _ExtendSheet(this.t);
  final PotToken t;
  @override
  State<_ExtendSheet> createState() => _ExtendSheetState();
}

class _ExtendSheetState extends State<_ExtendSheet> {
  final _minutes = TextEditingController(text: '30');
  final _fee = TextEditingController();
  PayMethod _method = PayMethod.mobileMoney;
  bool _busy = false;

  @override
  void dispose() {
    _minutes.dispose();
    _fee.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final m = int.tryParse(_minutes.text);
    final f = double.tryParse(_fee.text.replaceAll(',', ''));
    if (m == null || m <= 0 || f == null || f <= 0) {
      toast(context, 'Enter valid extra time and fee.', error: true);
      return;
    }
    setState(() => _busy = true);
    final b = context.read<Session>().backend;
    final r = await guarded(
        context,
        () => b.extendToken(
            tokenId: widget.t.id, minutes: m, fee: f, method: _method));
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Extend ${widget.t.potLabel} · ${widget.t.waiterName}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Extra minutes'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _fee,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Fee received'),
            ),
            const SizedBox(height: 14),
            const Text('Received by'),
            const SizedBox(height: 8),
            MethodPicker(value: _method, onChanged: (m) => setState(() => _method = m)),
            const SizedBox(height: 20),
            FilledButton(
                onPressed: _busy ? null : _save, child: const Text('Extend time')),
          ],
        ),
      ),
    );
  }
}
