import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import 'bluetooth_printer.dart';

/// Shown on every slip and report (and used as the text fallback if the logo
/// image can't be loaded).
const businessName = 'Arrows Bar';
const _logoAsset = 'assets/images/arrows_bar_logo.png';

pw.ImageProvider? _logoCache;

/// The Arrows Bar logo (with its name and tagline) for PDFs. Null if the asset
/// is unavailable, so printing never fails because of the image.
Future<pw.ImageProvider?> loadLogo() async {
  if (_logoCache != null) return _logoCache;
  try {
    final data = await rootBundle.load(_logoAsset);
    return _logoCache = pw.MemoryImage(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

/// Builds the 80mm receipt-style slip for one token.
/// Only characters in the built-in PDF font are used (no arrows etc.).
Future<Uint8List> buildTokenSlip(PotToken t) async {
  final doc = pw.Document(title: 'Token ${t.code}');
  final logo = await loadLogo();
  pw.Widget row(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(k, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(width: 8),
            pw.Flexible(
              child: pw.Text(v,
                  textAlign: pw.TextAlign.right,
                  style: const pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            ),
          ],
        ),
      );
  final divider = pw.Divider(thickness: .5, height: 10);

  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.roll80,
    margin: const pw.EdgeInsets.all(8),
    build: (_) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        if (logo != null)
          pw.Center(child: pw.Image(logo, width: 130))
        else
          pw.Text(businessName,
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text('POT TOKEN',
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 8, letterSpacing: 2)),
        divider,
        pw.Text(t.code,
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(
                fontSize: 30, fontWeight: pw.FontWeight.bold, letterSpacing: 4)),
        pw.SizedBox(height: 4),
        pw.Center(
          child: pw.BarcodeWidget(
              barcode: pw.Barcode.code128(),
              data: t.code,
              width: 170,
              height: 36,
              drawText: false),
        ),
        divider,
        row('Waiter', t.waiterName),
        if (t.potLabel != null) row('Pot', t.potLabel!),
        row('Time', minutesLabel(t.minutes)),
        row('Amount', money(t.amount)),
        if (t.paid)
          row('Paid by', t.method.label)
        else ...[
          row('Payment', 'UNPAID - ${t.payTiming.label.toLowerCase()}'),
          if (t.payDueAt != null) row('Pay by', dateTime(t.payDueAt!)),
        ],
        row('Issued', dateTime(t.issuedAt)),
        if (t.clearedAt != null) row('Due back', hm(t.clearedAt!.add(Duration(minutes: t.totalMinutes)))),
        if (t.distributorName != null) row('Served by', t.distributorName!),
        if (t.extensions.isNotEmpty) ...[
          divider,
          for (final e in t.extensions)
            row('+${e.minutes} min', '${money(e.fee)} ${e.method.label}'),
          row('Total time', minutesLabel(t.totalMinutes)),
          row('Total paid', money(t.totalFees)),
        ],
        divider,
        pw.Text(
          t.status == TokenStatus.returned
              ? 'Pot returned'
              : !t.paid
                  ? 'Payment due within 12 hours of issue'
                  : 'Return the pot when your time is up',
          textAlign: pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 8),
        ),
        pw.Text('Printed ${dateTime(DateTime.now())}',
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
      ],
    ),
  ));
  return doc.save();
}

// ---------------------------------------------------------------- printer

/// The printer the distributor chose once (kept on this device).
class SavedPrinter {
  static const _kUrl = 'printer_url';
  static const _kName = 'printer_name';

  static Future<Printer?> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final url = p.getString(_kUrl);
      if (url == null || url.isEmpty) return null;
      return Printer(url: url, name: p.getString(_kName));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Printer? printer) async {
    final p = await SharedPreferences.getInstance();
    if (printer == null) {
      await p.remove(_kUrl);
      await p.remove(_kName);
    } else {
      await p.setString(_kUrl, printer.url);
      await p.setString(_kName, printer.name);
    }
  }
}

/// Sends a PDF to the chosen printer with no dialog when this platform
/// supports it; otherwise (or if that fails) opens the system print dialog,
/// where any printer connected to the device (USB, Wi-Fi, Bluetooth) can be
/// picked.
Future<void> printPdf({
  required String name,
  required PdfPageFormat format,
  required Future<Uint8List> Function() build,
}) async {
  final chosen = await SavedPrinter.load();
  if (chosen != null) {
    try {
      if ((await Printing.info()).directPrint) {
        final ok = await Printing.directPrintPdf(
          printer: chosen,
          name: name,
          format: format,
          onLayout: (_) => build(),
        );
        if (ok) return;
      }
    } catch (_) {
      // printer offline / unsupported: fall through to the system dialog
    }
  }
  await Printing.layoutPdf(name: name, format: format, onLayout: (_) => build());
}

/// Token slips go to the Bluetooth printer if one was chosen (Android),
/// otherwise to the chosen/system printer.
Future<void> printTokenSlip(PotToken t) async {
  if (BluetoothPrinter.available) {
    final bt = await BluetoothChoice.load();
    if (bt != null) return BluetoothPrinter.printSlip(t, bt);
  }
  return printPdf(
    name: 'token-${t.code}.pdf',
    format: PdfPageFormat.roll80,
    build: () => buildTokenSlip(t),
  );
}

/// A4 sheet of tags (number + barcode) to stick on each pot.
Future<Uint8List> buildPotTags(List<Pot> pots) async {
  final doc = pw.Document(title: 'Pot tags');
  final logo = await loadLogo();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(24),
    header: (_) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Row(children: [
        if (logo != null) pw.Image(logo, height: 40),
        pw.SizedBox(width: 10),
        pw.Text('$businessName - pot tracking tags',
            style: const pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      ]),
    ),
    build: (_) => [
      pw.Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final p in pots)
            pw.Container(
              width: 170,
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey600),
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Column(children: [
                pw.Text(p.label,
                    style: const pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 4),
                pw.BarcodeWidget(
                    barcode: pw.Barcode.code128(),
                    data: p.label,
                    width: 140,
                    height: 30,
                    drawText: false),
              ]),
            ),
        ],
      ),
    ],
  ));
  return doc.save();
}

Future<void> printPotTags(List<Pot> pots) => printPdf(
      name: 'pot-tags.pdf',
      format: PdfPageFormat.a4,
      build: () => buildPotTags(pots),
    );
