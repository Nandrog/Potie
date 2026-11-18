import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../widgets/update_dialog.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Available to every role: edit login details, change password, pick theme.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<Session>().user!;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile & settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(children: [
              CircleAvatar(
                radius: 36,
                backgroundColor: Brand.amber,
                foregroundColor: Colors.black,
                child: Text(user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 10),
              Text(user.role.label,
                  style: TextStyle(color: Theme.of(context).hintColor)),
            ]),
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Login details'),
          const _DetailsCard(),
          const SizedBox(height: 24),
          const _SectionTitle('Password'),
          const _PasswordCard(),
          const SizedBox(height: 24),
          const _SectionTitle('Appearance'),
          const _ThemeCard(),
          const SizedBox(height: 24),
          const _SectionTitle('App'),
          const _UpdateCard(),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).popUntil((r) => r.isFirst);
              context.read<Session>().signOut();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _DetailsCard extends StatefulWidget {
  const _DetailsCard();
  @override
  State<_DetailsCard> createState() => _DetailsCardState();
}

class _DetailsCardState extends State<_DetailsCard> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: context.read<Session>().user!.name);
  late final _email = TextEditingController(text: context.read<Session>().user!.email);
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
    final s = context.read<Session>();
    final ok = await guarded(
        context, () => s.updateProfile(name: _name.text, email: _email.text).then((_) => true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) toast(context, 'Details updated. Use the new email next time you sign in.');
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _form,
            child: Column(children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Full name', prefixIcon: Icon(Icons.badge_outlined)),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Login email', prefixIcon: Icon(Icons.mail_outline)),
                validator: (v) => (v ?? '').contains('@') ? null : 'Enter a valid email',
              ),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _busy ? null : _save, child: const Text('Save details')),
            ]),
          ),
        ),
      );
}

class _PasswordCard extends StatefulWidget {
  const _PasswordCard();
  @override
  State<_PasswordCard> createState() => _PasswordCardState();
}

class _PasswordCardState extends State<_PasswordCard> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _hide = true;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final b = context.read<Session>().backend;
    final ok = await guarded(
        context,
        () => b
            .changePassword(current: _current.text, newPassword: _new.text)
            .then((_) => true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      _form.currentState!.reset();
      _current.clear();
      _new.clear();
      _confirm.clear();
      toast(context, 'Password changed.');
    }
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: () => setState(() => _hide = !_hide),
        ),
      );

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _form,
            child: Column(children: [
              TextFormField(
                controller: _current,
                obscureText: _hide,
                decoration: _dec('Current password'),
                validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _new,
                obscureText: _hide,
                decoration: _dec('New password'),
                validator: (v) =>
                    (v ?? '').length < 8 ? 'At least 8 characters' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _confirm,
                obscureText: _hide,
                decoration: _dec('Confirm new password'),
                validator: (v) => v != _new.text ? 'Passwords do not match' : null,
              ),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Change password')),
            ]),
          ),
        ),
      );
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard();
  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeController>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto),
                  label: Text('System')),
              ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light')),
              ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark')),
            ],
            selected: {t.mode},
            onSelectionChanged: (s) => t.set(s.first),
          ),
        ),
      ),
    );
  }
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard();
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (_, s) => Text(s.hasData
                ? 'Arrows Bar ${s.data!.version} (${s.data!.buildNumber})'
                : 'Arrows Bar'),
          ),
          subtitle: const Text('Tap to check for updates'),
          onTap: () => checkForUpdates(context),
        ),
      );
}
