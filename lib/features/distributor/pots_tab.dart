import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../print/print_service.dart';
import '../../widgets/shell.dart';

/// Pot inventory: register pots (random unique numbers), retire them, print tags.
class PotsTab extends StatefulWidget {
  const PotsTab({super.key});
  @override
  State<PotsTab> createState() => _PotsTabState();
}

class _PotsTabState extends State<PotsTab> {
  List<Pot>? _pots;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final p = await guarded(context, b.allPots);
    if (p != null && mounted) setState(() => _pots = p);
  }

  Future<void> _register() async {
    final made = await showDialog<List<Pot>>(
        context: context, builder: (_) => const _RegisterDialog());
    if (made == null || !mounted) return;
    await _load();
    if (!mounted) return;
    final print = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${made.length} pot${made.length == 1 ? '' : 's'} registered'),
        content: Text(made.map((p) => p.label).join('   ')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 40)),
            onPressed: () => Navigator.pop(c, true),
            icon: const Icon(Icons.print_outlined),
            label: const Text('Print tags'),
          ),
        ],
      ),
    );
    if (print == true && mounted) {
      await guarded(context, () => printPotTags(made));
    }
  }

  Future<void> _toggle(Pot p) async {
    final b = context.read<Session>().backend;
    await guarded(context, () => b.setPotActive(p.id, !p.active));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final pots = _pots;
    if (pots == null) return const Center(child: CircularProgressIndicator());
    final q = context.watch<SearchQuery>();
    final shown = pots
        .where((p) => q.matches([p.label, p.active ? (p.out ? 'out' : 'available') : 'retired']))
        .toList();
    final active = pots.where((p) => p.active).toList();
    final out = active.where((p) => p.out).length;
    final available = active.length - out;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _register,
        icon: const Icon(Icons.add),
        label: const Text('Register pots'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            Row(children: [
              _Stat('Total', active.length, Theme.of(context).colorScheme.onSurface),
              const SizedBox(width: 10),
              _Stat('Available', available, Brand.tealText(context)),
              const SizedBox(width: 10),
              _Stat('Out', out, Brand.amberText(context)),
            ]),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: active.isEmpty
                  ? null
                  : () => guarded(context, () => printPotTags(active)),
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print tags for all active pots'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            if (pots.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(
                  child: Text('No pots yet. Tap “Register pots” and enter how many you have.',
                      textAlign: TextAlign.center),
                ),
              ),
            if (shown.isEmpty && pots.isNotEmpty) NoResults(q),
            for (final p in shown)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(Icons.local_fire_department_outlined),
                  title: Text(p.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        decoration: p.active ? null : TextDecoration.lineThrough,
                      )),
                  subtitle: Text(!p.active
                      ? 'Retired'
                      : p.out
                          ? 'Out with a customer'
                          : 'Available'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'tag') {
                        guarded(context, () => printPotTags([p]));
                      } else {
                        _toggle(p);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'tag', child: Text('Print tag')),
                      PopupMenuItem(
                        value: 'toggle',
                        enabled: !p.out,
                        child: Text(p.active ? 'Retire pot' : 'Restore pot'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Text('$value',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: color)),
              Text(label, style: TextStyle(color: Theme.of(context).hintColor)),
            ]),
          ),
        ),
      );
}

class _RegisterDialog extends StatefulWidget {
  const _RegisterDialog();
  @override
  State<_RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends State<_RegisterDialog> {
  final _count = TextEditingController(text: '10');
  bool _busy = false;

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final n = int.tryParse(_count.text);
    if (n == null || n < 1 || n > 100) {
      toast(context, 'Enter a number from 1 to 100.', error: true);
      return;
    }
    setState(() => _busy = true);
    final b = context.read<Session>().backend;
    final made = await guarded(context, () => b.registerPots(n));
    if (!mounted) return;
    setState(() => _busy = false);
    if (made != null) Navigator.pop(context, made);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Register pots'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('How many pots are you adding? Each gets a random unique tracking number.'),
          const SizedBox(height: 14),
          TextField(
            controller: _count,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(labelText: 'Number of pots'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(110, 40)),
            onPressed: _busy ? null : _save,
            child: const Text('Register'),
          ),
        ],
      );
}
