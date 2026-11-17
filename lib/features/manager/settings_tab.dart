import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '587');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _fromName = TextEditingController(text: 'Arrows Bar');
  final _fromEmail = TextEditingController();
  bool _secure = false;
  bool _hide = true;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass, _fromName, _fromEmail]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final b = context.read<Session>().backend;
    final c = await guarded(context, b.getSmtp);
    if (c == null || !mounted) return;
    setState(() {
      _host.text = c.host;
      _port.text = c.port.toString();
      _user.text = c.username;
      _pass.text = c.password;
      _fromName.text = c.fromName;
      _fromEmail.text = c.fromEmail;
      _secure = c.secure;
      _loaded = true;
    });
  }

  SmtpConfig get _cfg => SmtpConfig(
        host: _host.text.trim(),
        port: int.tryParse(_port.text) ?? 587,
        secure: _secure,
        username: _user.text.trim(),
        password: _pass.text,
        fromName: _fromName.text.trim(),
        fromEmail: _fromEmail.text.trim(),
      );

  Future<void> _save() async {
    setState(() => _busy = true);
    final b = context.read<Session>().backend;
    final ok = await guarded(context, () => b.saveSmtp(_cfg).then((_) => true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) toast(context, 'SMTP settings saved.');
  }

  Future<void> _test() async {
    final me = context.read<Session>().user!;
    final b = context.read<Session>().backend;
    setState(() => _busy = true);
    final ok = await guarded(context, () async {
      await b.saveSmtp(_cfg);
      await b.testSmtp(me.email);
      return true;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) toast(context, 'Test email sent to ${me.email}.');
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Used to email login details to enrolled team members. '
          'For Gmail use smtp.gmail.com, port 587 and an App Password.',
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 16),
        TextField(
            controller: _host,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'SMTP host')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Port'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('SSL (465)'),
              value: _secure,
              onChanged: (v) => setState(() {
                _secure = v;
                _port.text = v ? '465' : '587';
              }),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
            controller: _user,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Username')),
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          obscureText: _hide,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Password / App password',
            suffixIcon: IconButton(
              icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _hide = !_hide),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
            controller: _fromName,
            decoration: const InputDecoration(labelText: 'Sender name')),
        const SizedBox(height: 12),
        TextField(
            controller: _fromEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Sender email')),
        const SizedBox(height: 20),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _busy ? null : _test,
          style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: const Text('Save & send test email to me'),
        ),
      ],
    );
  }
}
