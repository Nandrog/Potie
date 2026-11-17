import 'dart:async';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/format.dart';
import '../../core/models.dart';

/// The Bluetooth receipt printer chosen once on this device.
class BluetoothChoice {
  const BluetoothChoice({required this.mac, required this.name, this.wide = false});
  final String mac;
  final String name;

  /// 80 mm paper (true) or 58 mm (false).
  final bool wide;

  BluetoothChoice copyWith({bool? wide}) =>
      BluetoothChoice(mac: mac, name: name, wide: wide ?? this.wide);

  static const _kMac = 'bt_printer_mac';
  static const _kName = 'bt_printer_name';
  static const _kWide = 'bt_printer_wide';

  static Future<BluetoothChoice?> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final mac = p.getString(_kMac);
      if (mac == null || mac.isEmpty) return null;
      return BluetoothChoice(
          mac: mac,
          name: p.getString(_kName) ?? mac,
          wide: p.getBool(_kWide) ?? false);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(BluetoothChoice? c) async {
    final p = await SharedPreferences.getInstance();
    if (c == null) {
      await p.remove(_kMac);
      await p.remove(_kName);
      await p.remove(_kWide);
    } else {
      await p.setString(_kMac, c.mac);
      await p.setString(_kName, c.name);
      await p.setBool(_kWide, c.wide);
    }
  }
}

class BluetoothPrintException implements Exception {
  BluetoothPrintException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Prints token slips to a paired Bluetooth thermal (ESC/POS) printer.
/// Android only: iPhones can't talk to these printers.
class BluetoothPrinter {
  static bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Asks for the Bluetooth permission (Android 12+) and checks it is switched on.
  static Future<void> ensureReady() async {
    if (!available) {
      throw BluetoothPrintException('Bluetooth printing is only available on Android.');
    }
    final st = await Permission.bluetoothConnect.request();
    if (!st.isGranted) {
      throw BluetoothPrintException(
          'Allow the Bluetooth permission for this app in Android settings.');
    }
    if (!await PrintBluetoothThermal.bluetoothEnabled) {
      throw BluetoothPrintException('Bluetooth is off. Turn it on and try again.');
    }
  }

  /// Printers already paired in the phone's Bluetooth settings.
  static Future<List<BluetoothInfo>> paired() async {
    await ensureReady();
    return PrintBluetoothThermal.pairedBluetooths;
  }

  static Future<void> printSlip(PotToken t, BluetoothChoice c) async {
    await ensureReady();
    final bytes = await buildEscPosSlip(t, wide: c.wide);
    try {
      if (!await PrintBluetoothThermal.connectionStatus) {
        final ok = await PrintBluetoothThermal.connect(macPrinterAddress: c.mac);
        if (!ok) throw BluetoothPrintException('');
      }
      // Send in small pieces: cheap printers drop data from big writes.
      const chunk = 512;
      for (var i = 0; i < bytes.length; i += chunk) {
        final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
        if (!await PrintBluetoothThermal.writeBytes(bytes.sublist(i, end))) {
          throw BluetoothPrintException('');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    } on BluetoothPrintException {
      await PrintBluetoothThermal.disconnect;
      throw BluetoothPrintException(
          'Could not reach ${c.name}. Check it is switched on, in range and paired, then try again.');
    }
  }
}

/// ESC/POS bytes for one token: logo, big token number, barcode and details.
/// ASCII only, so any printer code page copes.
Future<List<int>> buildEscPosSlip(PotToken t, {bool wide = false}) async {
  final g = Generator(wide ? PaperSize.mm80 : PaperSize.mm58, await CapabilityProfile.load());
  final bytes = <int>[...g.reset()];

  try {
    final data = await rootBundle.load('assets/images/arrows_bar_logo.png');
    // Width must be a multiple of 8 (a limitation of the ESC/POS image encoder).
    final decoded = img.decodeImage(data.buffer.asUint8List());
    if (decoded != null) {
      bytes.addAll(g.imageRaster(img.copyResize(decoded, width: wide ? 400 : 288)));
    }
  } catch (e) {
    debugPrint('Logo not added to Bluetooth slip: $e');
    bytes.addAll(g.text('ARROWS BAR',
        styles: const PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2)));
  }

  PosColumn left(String s) => PosColumn(text: s, width: 5);
  PosColumn right(String s) =>
      PosColumn(text: s, width: 7, styles: const PosStyles(align: PosAlign.right, bold: true));
  List<int> row(String k, String v) => g.row([left(k), right(v)]);

  bytes
    ..addAll(g.text('POT TOKEN', styles: const PosStyles(align: PosAlign.center)))
    ..addAll(g.hr())
    ..addAll(g.text(t.code,
        styles: const PosStyles(
            align: PosAlign.center,
            bold: true,
            height: PosTextSize.size3,
            width: PosTextSize.size3)))
    ..addAll(g.feed(1))
    ..addAll(g.barcode(Barcode.code128('{B${t.code}'.split('')), height: 60))
    ..addAll(g.hr())
    ..addAll(row('Waiter', t.waiterName))
    ..addAll(t.potLabel == null ? <int>[] : row('Pot', t.potLabel!))
    ..addAll(row('Time', minutesLabel(t.minutes)))
    ..addAll(row('Amount', money(t.amount)))
    ..addAll(t.paid
        ? row('Paid by', t.method.label)
        : [
            ...row('Payment', 'UNPAID'),
            ...row('Option', t.payTiming.label),
            if (t.payDueAt != null) ...row('Pay by', dateTime(t.payDueAt!)),
          ])
    ..addAll(row('Issued', dateTime(t.issuedAt)));
  if (t.clearedAt != null) {
    bytes.addAll(row('Due back', hm(t.clearedAt!.add(Duration(minutes: t.totalMinutes)))));
  }
  if (t.distributorName != null) bytes.addAll(row('Served by', t.distributorName!));
  if (t.extensions.isNotEmpty) {
    bytes.addAll(g.hr());
    for (final e in t.extensions) {
      bytes.addAll(row('+${e.minutes} min', '${money(e.fee)} ${e.method.label}'));
    }
    bytes
      ..addAll(row('Total time', minutesLabel(t.totalMinutes)))
      ..addAll(row('Total paid', money(t.totalFees)));
  }
  bytes
    ..addAll(g.hr())
    ..addAll(g.text(
        t.status == TokenStatus.returned
            ? 'Pot returned'
            : !t.paid
                ? 'Payment due within 12 hours of issue'
                : 'Return the pot when your time is up',
        styles: const PosStyles(align: PosAlign.center)))
    ..addAll(g.text('Printed ${dateTime(DateTime.now())}',
        styles: const PosStyles(align: PosAlign.center)))
    ..addAll(g.feed(3))
    ..addAll(g.cut());
  return bytes;
}
