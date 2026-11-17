import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../print/print_service.dart';
import 'pdf_report.dart';

class ReportsTab extends StatefulWidget {
  const ReportsTab({super.key});
  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  late DateTimeRange _range = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 6)),
    end: DateTime.now(),
  );
  final _title = TextEditingController(text: 'Pot Activity Report');
  final _currency = TextEditingController(text: 'UGX');
  final _opts = ReportOptions();
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _currency.dispose();
    super.dispose();
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _generate() async {
    setState(() => _busy = true);
    final session = context.read<Session>();
    final b = session.backend;
    final from = DateTime(_range.start.year, _range.start.month, _range.start.day);
    final to = DateTime(_range.end.year, _range.end.month, _range.end.day)
        .add(const Duration(days: 1));
    final bytes = await guarded(context, () async {
      final tokens = await b.tokensBetween(from, to);
      final audit = _opts.audit ? await b.auditBetween(from, to) : [];
      return buildReport(
        title: _title.text.trim(),
        currency: _currency.text.trim(),
        from: from,
        to: to.subtract(const Duration(days: 1)),
        tokens: tokens,
        audit: audit.cast(),
        options: _opts,
        generatedBy: session.user!.name,
      );
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (bytes != null) {
      await guarded(
          context,
          () => printPdf(
              name: 'arrows-bar-report-${_range.start.toIso8601String().substring(0, 10)}.pdf',
              format: PdfPageFormat.a4,
              build: () async => bytes));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.date_range),
            title: Text('${dateOnly(_range.start)}  →  ${dateOnly(_range.end)}'),
            subtitle: const Text('Report period'),
            onTap: _pickRange,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Report title')),
        const SizedBox(height: 12),
        TextField(
            controller: _currency,
            decoration: const InputDecoration(labelText: 'Currency label')),
        const SizedBox(height: 14),
        Text('Include', style: Theme.of(context).textTheme.titleSmall),
        _check('Payment summary by method', _opts.payments, (v) => _opts.payments = v),
        _check('Waiter performance', _opts.waiters, (v) => _opts.waiters = v),
        _check('Pot movements (in / out / returned)', _opts.movements,
            (v) => _opts.movements = v),
        _check('Outstanding (unpaid) payments', _opts.outstanding, (v) => _opts.outstanding = v),
        _check('Extensions', _opts.extensions, (v) => _opts.extensions = v),
        _check('Audit trail', _opts.audit, (v) => _opts.audit = v),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.picture_as_pdf),
          label: const Text('Generate PDF'),
        ),
      ],
    );
  }

  Widget _check(String label, bool value, void Function(bool) set) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: (v) => setState(() => set(v ?? false)),
      );
}
