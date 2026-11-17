import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

class TeamTab extends StatefulWidget {
  const TeamTab({super.key});
  @override
  State<TeamTab> createState() => _TeamTabState();
}

class _TeamTabState extends State<TeamTab> {
  List<AppUser>? _users;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final u = await guarded(context, b.users);
    if (u != null && mounted) setState(() => _users = u);
  }

  Future<void> _enroll() async {
    final u = await showModalBottomSheet<AppUser>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _EnrollSheet(),
    );
    _load(); // refresh even if the sheet closed after a partial failure
    if (u != null && mounted) toast(context, '${u.name} enrolled. Login details emailed.');
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    final me = context.read<Session>().user!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _enroll,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Enroll'),
      ),
      body: users == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                itemCount: users.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final u = users[i];
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(u.name[0])),
                      title: Text(u.name),
                      subtitle: Text('${u.role.label} · ${u.email}'),
                      trailing: u.id == me.id
                          ? null
                          : PopupMenuButton<String>(
                              onSelected: (v) async {
                                final b = context.read<Session>().backend;
                                if (v == 'edit') {
                                  final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (_) => _EditUserDialog(u));
                                  if (ok == true) {
                                    _load();
                                    if (context.mounted) {
                                      toast(context, 'Details updated.');
                                    }
                                  }
                                } else if (v == 'resend') {
                                  final r = await guarded(context,
                                      () async => (await b.resendCredentials(u.id)) ?? '');
                                  if (r != null && context.mounted) {
                                    toast(context, 'New password emailed.');
                                  }
                                } else {
                                  await guarded(context,
                                      () => b.setUserActive(u.id, !u.active));
                                  _load();
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                    value: 'edit', child: Text('Edit name / login email')),
                                const PopupMenuItem(
                                    value: 'resend',
                                    child: Text('Email new login details')),
                                PopupMenuItem(
                                    value: 'toggle',
                                    child: Text(u.active ? 'Disable' : 'Enable')),
                              ],
                            ),
                      isThreeLine: false,
                      titleTextStyle: TextStyle(
                        fontSize: 16,
                        decoration: u.active ? null : TextDecoration.lineThrough,
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class _EditUserDialog extends StatefulWidget {
  const _EditUserDialog(this.user);
  final AppUser user;
  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  late final _name = TextEditingController(text: widget.user.name);
  late final _email = TextEditingController(text: widget.user.email);
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final b = context.read<Session>().backend;
    final u = await guarded(context,
        () => b.editUser(widget.user.id, name: _name.text, email: _email.text));
    if (!mounted) return;
    setState(() => _busy = false);
    if (u != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Edit ${widget.user.role.label.toLowerCase()}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Full name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Login email'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(90, 40)),
            onPressed: _busy ? null : _save,
            child: const Text('Save'),
          ),
        ],
      );
}

class _EnrollSheet extends StatefulWidget {
  const _EnrollSheet();
  @override
  State<_EnrollSheet> createState() => _EnrollSheetState();
}

class _EnrollSheetState extends State<_EnrollSheet> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  Role _role = Role.distributor;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final b = context.read<Session>().backend;
    final u = await guarded(context,
        () => b.enrollUser(name: _name.text, email: _email.text, role: _role));
    if (!mounted) return;
    setState(() => _busy = false);
    if (u != null) Navigator.pop(context, u);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Enroll a team member',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => (v ?? '').contains('@') ? null : 'Enter a valid email',
              ),
              const SizedBox(height: 14),
              SegmentedButton<Role>(
                showSelectedIcon: false,
                segments: [
                  for (final r in Role.values)
                    ButtonSegment(value: r, label: Text(r.label)),
                ],
                selected: {_role},
                onSelectionChanged: (s) => setState(() => _role = s.first),
              ),
              const SizedBox(height: 8),
              Text(
                'A temporary password is generated and emailed using your SMTP settings.',
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
              ),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Enroll & send login email')),
            ],
          ),
        ),
      );
}
