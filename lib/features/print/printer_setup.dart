import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/models.dart';
import '../../widgets/common.dart';
import 'bluetooth_printer.dart';
import 'print_service.dart';

/// App-bar button that opens [PrinterSetupDialog].
class PrinterButton extends StatelessWidget {
  const PrinterButton({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Printer',
        icon: const Icon(Icons.print_outlined),
        onPressed: () => showDialog<void>(
            context: context, builder: (_) => const PrinterSetupDialog()),
      );
}

/// Choose / clear the printer that tokens and reports are sent to, and print
/// a test slip.
class PrinterSetupDialog extends StatefulWidget {
  const PrinterSetupDialog({super.key});
  @override
  State<PrinterSetupDialog> createState() => _PrinterSetupDialogState();
}

class _PrinterSetupDialogState extends State<PrinterSetupDialog> {
  Printer? _printer;
  BluetoothChoice? _bt;
  bool _canPick = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SavedPrinter.load();
    final bt = await BluetoothChoice.load();
    var can = false;
    try {
      can = (await Printing.info()).canListPrinters;
    } catch (_) {}
    if (mounted) {
      setState(() {
        _printer = p;
        _bt = bt;
        _canPick = can;
        _loaded = true;
      });
    }
  }

  Future<void> _choose() async {
    final p = await Printing.pickPrinter(context: context, title: 'Select printer');
    if (p == null || !mounted) return;
    await SavedPrinter.save(p);
    setState(() => _printer = p);
  }

  Future<void> _chooseBluetooth() async {
    final list = await guarded(context, BluetoothPrinter.paired);
    if (list == null || !mounted) return;
    if (list.isEmpty) {
      toast(
          context,
          'No paired Bluetooth devices. Pair the printer in Android Bluetooth settings first (PIN is usually 0000 or 1234).',
          error: true);
      return;
    }
    final pick = await showDialog<BluetoothChoice>(
      context: context,
      builder: (d) => SimpleDialog(
        title: const Text('Select Bluetooth printer'),
        children: [
          for (final p in list)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                  d,
                  BluetoothChoice(
                      mac: p.macAdress, name: p.name, wide: _bt?.wide ?? false)),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bluetooth),
                title: Text(p.name),
                subtitle: Text(p.macAdress),
              ),
            ),
        ],
      ),
    );
    if (pick == null || !mounted) return;
    await BluetoothChoice.save(pick);
    setState(() => _bt = pick);
  }

  Future<void> _setWide(bool wide) async {
    final c = _bt?.copyWith(wide: wide);
    if (c == null) return;
    await BluetoothChoice.save(c);
    setState(() => _bt = c);
  }

  Future<void> _clearBluetooth() async {
    await BluetoothChoice.save(null);
    setState(() => _bt = null);
  }

  Future<void> _clear() async {
    await SavedPrinter.save(null);
    setState(() => _printer = null);
  }

  Future<void> _test() async {
    final now = DateTime.now();
    final t = PotToken(
      id: 'test',
      code: '000000',
      waiterId: 'test',
      waiterName: 'Test print',
      minutes: 60,
      amount: 0,
      method: PayMethod.cash,
      issuedAt: now,
      status: TokenStatus.out,
      potLabel: 'P-0000',
      clearedAt: now,
      paymentConfirmed: true,
    );
    await guarded(context, () => printTokenSlip(t));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Printer'),
      content: !_loaded
          ? const SizedBox(
              height: 60, child: Center(child: CircularProgressIndicator()))
          : SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (BluetoothPrinter.available) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bluetooth),
                    title: Text(_bt?.name ?? 'No Bluetooth printer'),
                    subtitle: Text(_bt == null
                        ? 'Pair the printer in Android Bluetooth settings, then choose it here.'
                        : 'Tokens print to this printer over Bluetooth.'),
                  ),
                  if (_bt != null) ...[
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: false, label: Text('58 mm paper')),
                        ButtonSegment(value: true, label: Text('80 mm paper')),
                      ],
                      selected: {_bt!.wide},
                      onSelectionChanged: (s) => _setWide(s.first),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(children: [
                    OutlinedButton.icon(
                      onPressed: _chooseBluetooth,
                      icon: const Icon(Icons.bluetooth_searching),
                      label: Text(_bt == null ? 'Choose' : 'Change'),
                    ),
                    if (_bt != null) ...[
                      const SizedBox(width: 8),
                      TextButton(onPressed: _clearBluetooth, child: const Text('Remove')),
                    ],
                  ]),
                  const Divider(height: 28),
                ],
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.print),
                  title: Text(_printer?.name ?? 'System printer'),
                  subtitle: Text(_printer == null
                      ? 'Reports and tags open the print dialog.'
                      : 'Reports and tags print straight to this printer.'),
                ),
                if (!_canPick)
                  Text(
                    'On this device the printer is chosen in the print dialog. '
                    'Pair or connect your printer (Bluetooth, Wi-Fi or USB) in the '
                    'phone’s print settings first, then pick it when printing.',
                    style: TextStyle(
                        color: Theme.of(context).hintColor, fontSize: 12),
                  ),
              ],
            )),
      actions: [
        if (_printer != null)
          TextButton(onPressed: _clear, child: const Text('Clear')),
        if (_canPick)
          TextButton(onPressed: _choose, child: const Text('Choose')),
        TextButton(onPressed: _test, child: const Text('Test print')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
