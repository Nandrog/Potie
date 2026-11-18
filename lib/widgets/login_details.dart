import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common.dart';

/// Shows a new user's sign-in details and lets the manager hand them over
/// from their own phone: email app, WhatsApp / SMS (share sheet) or copy.
/// This doesn't depend on the server's email being set up.
Future<void> showLoginDetails(
  BuildContext context, {
  required String name,
  required String email,
  required String role,
  required String password,
  bool renewed = false,
}) {
  final message = 'Hello $name,\n\n'
      '${renewed ? 'Your password for' : 'You have been added to'} Arrows Bar'
      '${renewed ? ' has been reset.' : ' as $role.'}\n\n'
      'Email: $email\n'
      'Temporary password: $password\n\n'
      'Sign in with these details, then change your password under Profile.';

  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(renewed ? 'New password' : '$name added'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Send these login details to them now. '
                'The password is not shown again.'),
            const SizedBox(height: 14),
            _Line('Email', email),
            _Line('Password', password),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message));
            toast(c, 'Copied');
          },
        ),
        TextButton.icon(
          icon: const Icon(Icons.share_outlined),
          label: const Text('WhatsApp / SMS'),
          onPressed: () => SharePlus.instance.share(ShareParams(
              text: message, subject: 'Your Arrows Bar login')),
        ),
        TextButton.icon(
          icon: const Icon(Icons.mail_outline),
          label: const Text('Email'),
          onPressed: () async {
            final uri = Uri.parse('mailto:$email'
                '?subject=${Uri.encodeComponent('Your Arrows Bar login')}'
                '&body=${Uri.encodeComponent(message)}');
            final ok = await launchUrl(uri).catchError((_) => false);
            if (!ok && c.mounted) {
              toast(c, 'No email app found. Use Copy or WhatsApp / SMS.',
                  error: true);
            }
          },
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
          onPressed: () => Navigator.pop(c),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
              width: 80,
              child: Text(label,
                  style: TextStyle(color: Theme.of(context).hintColor))),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontFamily: 'monospace')),
          ),
        ]),
      );
}
