import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/shell.dart';

class DayPicker extends StatelessWidget {
  const DayPicker({super.key, required this.day, required this.onChanged});
  final DateTime day;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        IconButton(
            onPressed: () => onChanged(day.subtract(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_left)),
        Expanded(
          child: TextButton(
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: day,
                firstDate: DateTime(2024),
                lastDate: DateTime.now(),
              );
              if (d != null) onChanged(d);
            },
            child: Text(dateOnly(day), style: const TextStyle(fontSize: 16)),
          ),
        ),
        IconButton(
            onPressed: DateUtils.isSameDay(day, DateTime.now())
                ? null
                : () => onChanged(day.add(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_right)),
      ]);
}

class DayTab extends StatefulWidget {
  const DayTab({super.key});
  @override
  State<DayTab> createState() => _DayTabState();
}

class _DayTabState extends State<DayTab> {
  DateTime _day = DateTime.now();
  DaySummary? _s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final s = await guarded(context, () => b.daySummary(_day));
    if (s != null && mounted) setState(() => _s = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final q = context.watch<SearchQuery>();
    final moves = s == null
        ? const <PotToken>[]
        : s.tokens.reversed
            .where((t) => q.matches(
                [t.potLabel, t.waiterName, t.distributorName, t.method.label, t.status.name]))
            .toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DayPicker(
              day: _day,
              onChanged: (d) {
                setState(() {
                  _day = d;
                  _s = null;
                });
                _load();
              }),
          const SizedBox(height: 8),
          if (s == null)
            const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()))
          else ...[
            _Totals(s),
            const SizedBox(height: 20),
            Text('Waiters who worked (${s.waiters.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (s.waiters.isEmpty)
              const Text('Nobody issued a token on this day.')
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final w in s.waiters)
                  Chip(
                    avatar: const Icon(Icons.person, size: 18),
                    label: Text(
                        '$w · ${s.tokens.where((t) => t.waiterName == w).length}'),
                  ),
              ]),
            const SizedBox(height: 20),
            Text('Pot movements (${s.tokens.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (moves.isEmpty && s.tokens.isNotEmpty) NoResults(q),
            for (final t in moves) ...[
              _Movement(t),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals(this.s);
  final DaySummary s;
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text('Total collected', style: TextStyle(color: Theme.of(context).hintColor)),
          Text(money(s.total),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Row(children: [
            for (final m in PayMethod.values)
              Expanded(
                child: Column(children: [
                  Text(m.label, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 2),
                  Text(money(s.totalFor(m)),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
          ]),
        ]),
      ),
    );
  }
}

class _Movement extends StatelessWidget {
  const _Movement(this.t);
  final PotToken t;
  @override
  Widget build(BuildContext context) {
    String line(String label, DateTime? d, [String? who]) =>
        d == null ? '' : '$label ${hm(d)}${who == null ? '' : ' ($who)'}   ';
    return TokenCard(
      t,
      showWaiter: true,
      trailing: Text(
        '${line('Issued', t.issuedAt, t.waiterName)}'
        '${line('Out', t.clearedAt, t.distributorName)}'
        '${line('Back', t.returnedAt)}'
        '${t.extensions.isEmpty ? '' : '\n${t.extensions.length} extension(s)'}',
        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
      ),
    );
  }
}
