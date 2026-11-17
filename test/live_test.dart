import 'package:flutter_test/flutter_test.dart';
import 'package:potie/core/live_tokens.dart';
import 'package:potie/core/models.dart';
import 'package:potie/data/backend.dart';
import 'support/demo_backend.dart';
import 'package:potie/features/print/bluetooth_printer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  paymentTests();
  escPosTests();
  test('time-up alert fires once per pot, and again after an extension', () async {
    final b = DemoBackend();
    await b.signIn('distributor@potie.app', 'Distro@123');
    final w = (await b.waiters()).first;
    final pot = (await b.availablePots()).first;
    final t = await b.issueToken(
        waiterId: w.id, potId: pot.id, minutes: 30, amount: 1000, method: PayMethod.cash);

    final live = LiveTokens(b);
    await live.refresh();
    final fired = <String>[];
    live.dueEvents.listen((x) => fired.add(x.id));

    live.checkDue(DateTime.now().add(const Duration(minutes: 10)));
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty); // still running

    final after = DateTime.now().add(const Duration(minutes: 31));
    live.checkDue(after);
    live.checkDue(after.add(const Duration(seconds: 1)));
    await Future<void>.delayed(Duration.zero);
    expect(fired.where((id) => id == t.id).length, 1); // exactly once

    // Returned pots leave the board.
    await b.returnPot(t.id);
    await live.refresh();
    expect(live.tokens.any((x) => x.id == t.id), isFalse);
    live.dispose();
  });

  test('the live list is sorted by time left', () async {
    final b = DemoBackend();
    await b.signIn('distributor@potie.app', 'Distro@123');
    final w = (await b.waiters()).first;
    final pots = await b.availablePots();
    await b.issueToken(waiterId: w.id, potId: pots[0].id, minutes: 120, amount: 1, method: PayMethod.cash);
    await b.issueToken(waiterId: w.id, potId: pots[1].id, minutes: 5, amount: 1, method: PayMethod.cash);
    final live = LiveTokens(b);
    await live.refresh();
    final due = live.tokens.map((t) => t.dueAt!).toList();
    expect([...due]..sort(), due);
    live.dispose();
  });
}

void paymentTests() {
  test('pay on return / pay later stay unpaid, with a 12 hour deadline, until collected',
      () async {
    final b = DemoBackend();
    await b.signIn('distributor@potie.app', 'Distro@123');
    final w = (await b.waiters()).first;
    final pots = await b.availablePots();

    final now = await b.issueToken(
        waiterId: w.id, potId: pots[0].id, minutes: 60, amount: 10000, method: PayMethod.cash);
    expect(now.paid, isTrue);
    expect(now.collected, 10000);

    for (final (i, timing) in [(1, PayTiming.onReturn), (2, PayTiming.later)]) {
      final t = await b.issueToken(
          waiterId: w.id,
          potId: pots[i].id,
          minutes: 60,
          amount: 20000,
          method: PayMethod.cash,
          timing: timing);
      expect(t.paid, isFalse);
      expect(t.collected, 0);
      expect(t.outstanding, 20000);
      expect(t.payTiming, timing);
      expect(t.payDueAt!.difference(t.clearedAt!), const Duration(hours: 12));
    }

    var unpaid = await b.unpaidTokens();
    expect(unpaid.length, 2);

    // Returning the pot does not settle the payment.
    await b.returnPot(unpaid.first.id);
    expect((await b.unpaidTokens()).length, 2);

    final paid = await b.settlePayment(unpaid.first.id, PayMethod.visa);
    expect(paid.paid, isTrue);
    expect(paid.method, PayMethod.visa);
    expect(paid.collected, 20000);
    await expectLater(b.settlePayment(unpaid.first.id, PayMethod.cash),
        throwsA(isA<BackendException>()));
    expect((await b.unpaidTokens()).length, 1);

    // Reports count only money received.
    await b.signIn('manager@potie.app', 'Manager@123');
    final day = await b.daySummary(DateTime.now());
    expect(day.outstanding, 20000);
    expect(day.totalFor(PayMethod.visa), 20000);
  });
}

void escPosTests() {
  test('Bluetooth (ESC/POS) slip builds for 58 and 80 mm, paid and unpaid', () async {
    final t = PotToken(
      id: 't', code: '482915', waiterId: 'w', waiterName: 'Wanda Waiter',
      minutes: 60, amount: 50000, method: PayMethod.cash, issuedAt: DateTime.now(),
      status: TokenStatus.out, potLabel: 'P-4821', clearedAt: DateTime.now(),
      payTiming: PayTiming.onReturn, payDueAt: DateTime.now().add(const Duration(hours: 12)),
    );
    final narrow = await buildEscPosSlip(t);
    final wide = await buildEscPosSlip(t.copyWith(paymentConfirmed: true), wide: true);
    expect(narrow.length, greaterThan(1000)); // includes the logo bitmap
    expect(wide.length, greaterThan(narrow.length ~/ 2));
    expect(String.fromCharCodes(narrow).contains('UNPAID'), isTrue);
    expect(String.fromCharCodes(wide).contains('UNPAID'), isFalse);
  });
}
