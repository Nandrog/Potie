import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import 'day_tab.dart';

class AuditTab extends StatefulWidget {
  const AuditTab({super.key});
  @override
  State<AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<AuditTab> {
  DateTime _day = DateTime.now();
  List<AuditEntry>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final from = DateTime(_day.year, _day.month, _day.day);
    final l = await guarded(
        context, () => b.auditBetween(from, from.add(const Duration(days: 1))));
    if (l != null && mounted) setState(() => _list = l);
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: DayPicker(
            day: _day,
            onChanged: (d) {
              setState(() {
                _day = d;
                _list = null;
              });
              _load();
            }),
      ),
      Expanded(
        child: l == null
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: l.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 120),
                        Center(child: Text('No activity on this day.')),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: l.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final a = l[i];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Text(hm(a.at),
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                            title: Text(a.detail),
                            subtitle: Text(
                                '${a.action.replaceAll('_', ' ')} · ${a.actorName} (${a.actorRole.label})'),
                          );
                        },
                      ),
              ),
      ),
    ]);
  }
}
