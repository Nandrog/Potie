import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/backend.dart' show BackendException;
import '../../widgets/common.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// Set when the server says this account is locked; sign-in stays disabled
  /// (with a live countdown) until it passes.
  DateTime? _lockedUntil;

  Duration get _lockLeft => _lockedUntil?.difference(DateTime.now()) ?? Duration.zero;
  bool get _locked => !_lockLeft.isNegative && _lockLeft > Duration.zero;

  Future<void> _submit() async {
    if (_locked || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final s = context.read<Session>();
    try {
      await s.signIn(_email.text, _pass.text);
    } on BackendException catch (e) {
      if (!mounted) return;
      setState(() => _lockedUntil = e.lockedUntil);
      toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) toast(context, e.toString(), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _forgot() async {
    if (_email.text.trim().isEmpty) {
      toast(context, 'Enter your email first.', error: true);
      return;
    }
    final s = context.read<Session>();
    final ok = await guarded(
        context, () => s.backend.sendPasswordReset(_email.text).then((_) => true));
    if (ok == true && mounted) toast(context, 'Password reset email sent.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(actions: const [ThemeToggleButton(), SizedBox(width: 8)]),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(12),
                          child: Image.asset('assets/images/arrows_bar_logo.png',
                              width: 200),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('Pot tracking',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).hintColor)),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                          labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                      validator: (v) => (v == null || !v.contains('@'))
                          ? 'Enter a valid email'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _pass,
                      obscureText: _hide,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _hide ? 'Show password' : 'Hide password',
                          icon: Icon(_hide
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _hide = !_hide),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Enter your password' : null,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          onPressed: _forgot, child: const Text('Forgot password?')),
                    ),
                    const SizedBox(height: 8),
                    // Re-evaluated every second so the countdown runs and the
                    // button re-enables itself the moment the lock ends.
                    Ticking(builder: (_) {
                      final locked = _locked;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (locked) _LockBanner(_lockLeft),
                          FilledButton(
                            onPressed: _busy || locked ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2.5))
                                : Text(locked ? 'Locked' : 'Sign in'),
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockBanner extends StatelessWidget {
  const _LockBanner(this.left);
  final Duration left;
  @override
  Widget build(BuildContext context) {
    final secs = left.inSeconds + (left.inMilliseconds % 1000 > 0 ? 1 : 0);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.danger.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Brand.danger.withValues(alpha: .4)),
      ),
      child: Row(children: [
        const Icon(Icons.lock_clock, color: Brand.danger),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Too many failed attempts. Try again in $secs second${secs == 1 ? '' : 's'}.\n'
            'Your manager has been alerted.',
          ),
        ),
      ]),
    );
  }
}
