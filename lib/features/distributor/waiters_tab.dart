import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/shell.dart';

/// The distributor registers the waiters. They have no login; a waiter just
/// needs to exist so pots and tokens can be issued to them by name.
class WaitersTab extends StatefulWidget {
  const WaitersTab({super.key});
  @override
  State<WaitersTab> createState() => _WaitersTabState();
}

class _WaitersTabState extends State<WaitersTab> {
  List<Waiter>? _waiters;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final l = await guarded(context, () => b.waiters(all: true));
    if (l != null && mounted) setState(() => _waiters = l);
  }

  Future<String?> _askName(String title, {String initial = ''}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Waiter name'),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(90, 40)),
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final name = await _askName('Register a waiter');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final b = context.read<Session>().backend;
    final w = await guarded(context, () => b.registerWaiter(name));
    if (w != null && mounted) toast(context, '${w.name} registered.');
    _load();
  }

  Future<void> _rename(Waiter w) async {
    final name = await _askName('Rename waiter', initial: w.name);
    if (name == null || name.trim().isEmpty || !mounted) return;
    final b = context.read<Session>().backend;
    await guarded(context, () => b.updateWaiter(w.id, name: name));
    _load();
  }

  Future<void> _toggle(Waiter w) async {
    final b = context.read<Session>().backend;
    await guarded(context, () => b.updateWaiter(w.id, active: !w.active));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = context.watch<SearchQuery>();
    final all = _waiters;
    final list = all?.where((w) => q.matches([w.name])).toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Register waiter'),
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: list.isEmpty
                  ? ListView(children: [
                      const SizedBox(height: 160),
                      Center(
                          child: (all?.isNotEmpty ?? false) && q.filtering
                              ? NoResults(q)
                              : const Text('No waiters yet. Tap “Register waiter”.')),
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final w = list[i];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(child: Text(w.name[0].toUpperCase())),
                            title: Text(
                              w.name,
                              style: TextStyle(
                                decoration:
                                    w.active ? null : TextDecoration.lineThrough,
                              ),
                            ),
                            subtitle: w.active ? null : const Text('Retired'),
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) => v == 'rename' ? _rename(w) : _toggle(w),
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                    value: 'rename', child: Text('Rename')),
                                PopupMenuItem(
                                    value: 'toggle',
                                    child: Text(w.active ? 'Retire' : 'Restore')),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
