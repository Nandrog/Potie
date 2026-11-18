import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/updater.dart';
import 'common.dart';

/// Checks for a newer release and, if there is one, offers to install it.
/// [silent] = used on app start: say nothing when up to date or offline.
Future<void> checkForUpdates(BuildContext context, {bool silent = false}) async {
  if (!Updater.supported) {
    if (!silent) toast(context, 'Updates are installed from the Android app.');
    return;
  }
  final updater = Updater();
  try {
    final info = await updater.check();
    if (!context.mounted) return;
    if (info == null) {
      if (!silent) toast(context, 'You have the latest version.');
      return;
    }
    final mandatory = Updater.isMandatory(info, await Updater.installedBuild());
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: !mandatory,
      builder: (_) => _UpdateDialog(updater, info, mandatory: mandatory),
    );
  } catch (e) {
    if (!silent && context.mounted) {
      toast(context, 'Could not check for updates. Check your internet connection.',
          error: true);
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.updater, this.info, {required this.mandatory});
  final Updater updater;
  final UpdateInfo info;
  final bool mandatory;
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null = not started
  String? _error;

  Future<void> _go() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final file = await widget.updater
          .download(widget.info, (p) => mounted ? setState(() => _progress = p) : null);
      await widget.updater.install(file);
      if (mounted && !widget.mandatory) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final busy = _progress != null;
    return PopScope(
      canPop: !widget.mandatory && !busy,
      child: AlertDialog(
        title: Text(widget.mandatory ? 'Update required' : 'Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version ${i.versionName} (${i.versionCode}) is ready.'),
            if (i.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(i.notes),
            ],
            if (busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
              const SizedBox(height: 6),
              Text(_progress == 1
                  ? 'Opening the installer...'
                  : 'Downloading ${percent(_progress!)}'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (!busy)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Android will ask you to confirm the install. Your data stays in the cloud.',
                  style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
                ),
              ),
          ],
        ),
        actions: [
          if (!widget.mandatory && !busy)
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(110, 40)),
            onPressed: busy ? null : _go,
            child: Text(_error == null ? 'Update now' : 'Try again'),
          ),
        ],
      ),
    );
  }
}
