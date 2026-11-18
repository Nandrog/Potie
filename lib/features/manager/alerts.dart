import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/login_details.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Bell in the manager's app bar; the badge counts open lockout alerts.
class AlertsButton extends StatefulWidget {
  const AlertsButton({super.key});
  @override
  State<AlertsButton> createState() => _AlertsButtonState();
}

class _AlertsButtonState extends State<AlertsButton> {
  int _count = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final a = await context.read<Session>().backend.alerts();
      if (mounted) setState(() => _count = a.length);
    } catch (_) {/* badge just stays as it was */}
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Security alerts',
        icon: Badge(
          isLabelVisible: _count > 0,
          label: Text('$_count'),
          backgroundColor: Brand.danger,
          child: const Icon(Icons.notifications_outlined),
        ),
        onPressed: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const AlertsPage()));
          _refresh();
        },
      );
}

class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});
  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  List<SecurityAlert>? _alerts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final a = await guarded(context, b.alerts);
    if (a != null && mounted) setState(() => _alerts = a);
  }

  Future<void> _renew(SecurityAlert a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Renew password for ${a.userName}?'),
        content: Text('A new temporary password is created for ${a.userName} '
            'and the lockout is lifted. You then send them the password.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(110, 40)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Renew password'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final b = context.read<Session>().backend;
    final pw = await guarded(context, () => b.resendCredentials(a.userId));
    if (pw == null || !mounted) return;
    await showLoginDetails(context,
        name: a.userName,
        email: a.userEmail,
        role: a.userRole.label,
        password: pw,
        renewed: true);
    _load();
  }

  Future<void> _dismiss(SecurityAlert a) async {
    final b = context.read<Session>().backend;
    await guarded(context, () => b.dismissAlert(a.id));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _alerts;
    return Scaffold(
      appBar: AppBar(title: const Text('Security alerts')),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: list.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 160),
                      Center(child: Text('No open alerts.')),
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) {
                        final a = list[i];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Icon(Icons.lock_person_outlined, color: Brand.danger),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(a.userName,
                                        style: const TextStyle(
                                            fontSize: 16, fontWeight: FontWeight.w700)),
                                  ),
                                  Text(dateTime(a.at),
                                      style: TextStyle(
                                          fontSize: 12, color: Theme.of(context).hintColor)),
                                ]),
                                const SizedBox(height: 8),
                                Text(a.message),
                                const SizedBox(height: 14),
                                Row(children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                                      onPressed: () => _renew(a),
                                      icon: const Icon(Icons.mark_email_read_outlined),
                                      label: const Text('Renew password'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton(
                                      onPressed: () => _dismiss(a), child: const Text('Dismiss')),
                                ]),
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
