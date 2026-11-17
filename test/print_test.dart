import 'package:flutter_test/flutter_test.dart';
import 'package:potie/core/models.dart';
import 'package:potie/features/manager/pdf_report.dart';
import 'package:potie/features/print/print_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PotToken token({List<Extension> ext = const []}) => PotToken(
        id: 't',
        code: '482915',
        waiterId: 'w',
        waiterName: 'Wanda Waiter',
        minutes: 60,
        amount: 50000,
        method: PayMethod.cash,
        issuedAt: DateTime.now(),
        status: TokenStatus.out,
        distributorName: 'Derrick Distributor',
        potLabel: 'P-4821',
        clearedAt: DateTime.now(),
        extensions: ext,
      );

  bool isPdf(List<int> b) => b.length > 500 && String.fromCharCodes(b.take(4)) == '%PDF';

  test('the Arrows Bar logo is bundled and loads', () async {
    expect(await loadLogo(), isNotNull);
  });

  test('token slip renders as a PDF (with and without extensions)', () async {
    final plain = await buildTokenSlip(token());
    expect(isPdf(plain), isTrue);
    final ext = Extension(
        id: 'e', minutes: 30, fee: 20000, method: PayMethod.visa, at: DateTime.now(), confirmed: true);
    expect(isPdf(await buildTokenSlip(token(ext: [ext]))), isTrue);
    // The logo image is embedded in the slip (a text-only slip is far smaller).
    expect(plain.length, greaterThan(20000));
  });

  test('pot tag sheet renders as a PDF', () async {
    final pots = [for (var i = 0; i < 40; i++) Pot(id: '$i', label: 'P-${1000 + i}')];
    expect(isPdf(await buildPotTags(pots)), isTrue);
  });

  test('report renders as a PDF with the logo', () async {
    final bytes = await buildReport(
      title: 'Pot Activity Report',
      currency: 'UGX',
      from: DateTime.now(),
      to: DateTime.now(),
      tokens: [token()],
      audit: const [],
      options: ReportOptions(),
      generatedBy: 'Maria Manager',
    );
    expect(isPdf(bytes), isTrue);
    expect(bytes.length, greaterThan(20000));
  });
}
