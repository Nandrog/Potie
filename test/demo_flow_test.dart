import 'package:flutter_test/flutter_test.dart';
import 'package:potie/core/models.dart';
import 'package:potie/data/backend.dart';
import 'support/demo_backend.dart';

const distroEmail = 'distributor@potie.app';
const distroPw = 'Distro@123';
const mgrEmail = 'manager@potie.app';
const mgrPw = 'Manager@123';

void main() {
  test('distributor registers a waiter, issues a token, extends and records the return',
      () async {
    final b = DemoBackend();
    await b.signIn(distroEmail, distroPw);

    final w = await b.registerWaiter('  Walter Waiter ');
    expect(w.name, 'Walter Waiter');
    expect((await b.waiters()).map((x) => x.name), contains('Walter Waiter'));
    await expectLater(b.registerWaiter('  '), throwsA(isA<BackendException>()));

    final pot = (await b.availablePots()).first;
    final t = await b.issueToken(
        waiterId: w.id,
        potId: pot.id,
        minutes: 60,
        amount: 50000,
        method: PayMethod.cash);
    expect(t.code, matches(RegExp(r'^\d{6}$')));
    expect(t.status, TokenStatus.out); // timer starts straight away
    expect(t.waiterName, 'Walter Waiter');
    expect(t.potLabel, pot.label);
    expect(t.remaining!.inMinutes, inInclusiveRange(58, 60));

    // The pot is now out and can't be issued twice.
    expect((await b.availablePots()).any((p) => p.id == pot.id), isFalse);
    await expectLater(
        b.issueToken(
            waiterId: w.id,
            potId: pot.id,
            minutes: 30,
            amount: 1000,
            method: PayMethod.cash),
        throwsA(isA<BackendException>()));

    final ext = await b.extendToken(
        tokenId: t.id, minutes: 30, fee: 20000, method: PayMethod.visa);
    expect(ext.totalMinutes, 90);
    expect(ext.totalFees, 70000);
    expect(ext.extensions.single.confirmed, isTrue);

    final back = await b.returnPot(t.id);
    expect(back.status, TokenStatus.returned);
    expect(back.returnedAt, isNotNull);
    await expectLater(b.returnPot(t.id), throwsA(isA<BackendException>()));

    await b.signIn(mgrEmail, mgrPw);
    final day = await b.daySummary(DateTime.now());
    expect(day.waiters, contains('Walter Waiter'));
    expect(day.totalFor(PayMethod.visa), 20000);
    expect(day.audit.any((a) => a.action == 'WAITER_REGISTERED'), isTrue);
    expect(day.audit.any((a) => a.action == 'POT_OUT'), isTrue);
    expect(day.audit.any((a) => a.action == 'POT_RETURNED'), isTrue);
  });

  test('retired waiters cannot be chosen, and not while a pot is out', () async {
    final b = DemoBackend();
    await b.signIn(distroEmail, distroPw);
    final w = await b.registerWaiter('Temp Waiter');
    final pot = (await b.availablePots()).first;
    final t = await b.issueToken(
        waiterId: w.id, potId: pot.id, minutes: 30, amount: 5000, method: PayMethod.cash);

    await expectLater(
        b.updateWaiter(w.id, active: false), throwsA(isA<BackendException>()));
    await b.returnPot(t.id);

    final renamed = await b.updateWaiter(w.id, name: 'Tempest');
    expect(renamed.name, 'Tempest');
    await b.updateWaiter(w.id, active: false);
    expect((await b.waiters()).any((x) => x.id == w.id), isFalse);
    expect((await b.waiters(all: true)).any((x) => x.id == w.id), isTrue);
    await expectLater(
        b.issueToken(
            waiterId: w.id, potId: pot.id, minutes: 30, amount: 5000, method: PayMethod.cash),
        throwsA(isA<BackendException>()));
  });

  test('enrolling returns a temporary password the manager can hand over', () async {
    final b = DemoBackend();
    await b.signIn(mgrEmail, mgrPw);
    final r = await b.enrollUser(
        name: 'New Distro', email: 'new.distro@potie.app', role: Role.distributor);
    expect(r.user.role, Role.distributor);
    expect(r.tempPassword, isNotNull);
    await b.signOut();
    final u = await b.signIn('new.distro@potie.app', r.tempPassword!);
    expect(u.name, 'New Distro');
  });

  test('manager deletes a user: login gone, history kept, not themselves', () async {
    final b = DemoBackend();
    await b.signIn(mgrEmail, mgrPw);
    final me = (await b.users()).firstWhere((u) => u.role == Role.manager);
    await expectLater(b.deleteUser(me.id), throwsA(isA<BackendException>()));

    // The distributor issues a pot, then gets deleted.
    await b.signIn(distroEmail, distroPw);
    final w = (await b.waiters()).first;
    final pot = (await b.availablePots()).first;
    await b.issueToken(
        waiterId: w.id, potId: pot.id, minutes: 30, amount: 1000, method: PayMethod.cash);

    await b.signIn(mgrEmail, mgrPw);
    final d = (await b.users()).firstWhere((u) => u.role == Role.distributor);
    await b.deleteUser(d.id);
    expect((await b.users()).any((u) => u.id == d.id), isFalse);
    await expectLater(b.deleteUser(d.id), throwsA(isA<BackendException>()));

    final day = await b.daySummary(DateTime.now());
    expect(day.audit.any((a) => a.action == 'USER_DELETED'), isTrue);
    expect(day.audit.any((a) => a.actorName == d.name), isTrue); // their past activity stays

    await b.signOut();
    await expectLater(b.signIn(distroEmail, distroPw), throwsA(isA<BackendException>()));
  });

  test('waiters have no login', () async {
    final b = DemoBackend();
    await expectLater(b.signIn('waiter1@potie.app', 'Waiter@123'),
        throwsA(isA<BackendException>()));
  });

  test('profile: change email and password, then log in with the new ones',
      () async {
    final b = DemoBackend();
    await b.signIn(mgrEmail, mgrPw);

    await expectLater(
        b.changePassword(current: 'wrong', newPassword: 'Another#123'),
        throwsA(isA<BackendException>()));
    await expectLater(
        b.changePassword(current: mgrPw, newPassword: 'short'),
        throwsA(isA<BackendException>()));

    final u = await b.updateProfile(name: 'Mary M', email: 'Mary@Potie.app');
    expect(u.email, 'mary@potie.app');
    await b.changePassword(current: mgrPw, newPassword: 'Another#123');

    await b.signOut();
    await expectLater(b.signIn(mgrEmail, mgrPw), throwsA(isA<BackendException>()));
    final back = await b.signIn('mary@potie.app', 'Another#123');
    expect(back.name, 'Mary M');
  });

  test('manager can edit a team member, others cannot', () async {
    final b = DemoBackend();
    await b.signIn(mgrEmail, mgrPw);
    final d = (await b.users()).firstWhere((u) => u.role == Role.distributor);
    final edited = await b.editUser(d.id, name: 'Dee D', email: 'dee@potie.app');
    expect(edited.email, 'dee@potie.app');
    await expectLater(b.editUser(d.id, name: 'X', email: mgrEmail),
        throwsA(isA<BackendException>())); // email already taken

    await b.signIn('dee@potie.app', distroPw);
    await expectLater(b.editUser(d.id, name: 'Hax', email: 'h@x.io'),
        throwsA(isA<BackendException>()));
  });

  test('distributor registers pots with unique random numbers', () async {
    final b = DemoBackend();
    await b.signIn(distroEmail, distroPw);
    final before = (await b.allPots()).length;
    final made = await b.registerPots(60);
    expect(made.length, 60);
    final all = await b.allPots();
    expect(all.length, before + 60);
    expect(all.map((p) => p.label).toSet().length, all.length); // all unique
    expect(made.every((p) => RegExp(r'^P-\d{4}$').hasMatch(p.label)), isTrue);

    await expectLater(b.registerPots(0), throwsA(isA<BackendException>()));
    await expectLater(b.registerPots(101), throwsA(isA<BackendException>()));

    // Retired pots can't be issued; pots that are out can't be retired.
    await b.setPotActive(made.first.id, false);
    expect((await b.availablePots()).any((p) => p.id == made.first.id), isFalse);
    final out = all.firstWhere((p) => p.out);
    await expectLater(
        b.setPotActive(out.id, false), throwsA(isA<BackendException>()));

    await b.signIn(mgrEmail, mgrPw);
    await expectLater(b.registerPots(5), throwsA(isA<BackendException>()));
  });

  group('sign-in lockout (10 seconds)', () {
    late DateTime now;
    late DemoBackend b;
    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      b = DemoBackend(clock: () => now);
    });

    Future<void> fail(String email, [int times = 1]) async {
      for (var i = 0; i < times; i++) {
        try {
          await b.signIn(email, 'wrong');
        } on BackendException {/* expected */}
      }
    }

    test('counts down, locks on the 3rd failure, and blocks even the right password',
        () async {
      await expectLater(
          b.signIn(distroEmail, 'x'),
          throwsA(isA<BackendException>()
              .having((e) => e.message, 'message', contains('2 attempts left'))));
      await expectLater(
          b.signIn(distroEmail, 'x'),
          throwsA(isA<BackendException>()
              .having((e) => e.message, 'message', contains('1 attempt left'))));
      await expectLater(
          b.signIn(distroEmail, 'x'),
          throwsA(isA<BackendException>().having((e) => e.lockedUntil,
              'lockedUntil', now.add(const Duration(seconds: 10)))));

      // Correct password is refused while locked.
      await expectLater(
          b.signIn(distroEmail, distroPw),
          throwsA(isA<BackendException>().having((e) => e.lockedUntil, 'locked', isNotNull)));
      now = now.add(const Duration(seconds: 9));
      await expectLater(
          b.signIn(distroEmail, distroPw), throwsA(isA<BackendException>()));
    });

    test('can sign in again once 10 seconds have passed', () async {
      await fail(distroEmail, 3);
      now = now.add(const Duration(seconds: 11));
      final u = await b.signIn(distroEmail, distroPw);
      expect(u.role, Role.distributor);
    });

    test('after the lock lapses the attempts start again from zero', () async {
      await fail(distroEmail, 3);
      now = now.add(const Duration(seconds: 11));
      await expectLater(
          b.signIn(distroEmail, 'x'),
          throwsA(isA<BackendException>()
              .having((e) => e.message, 'message', contains('2 attempts left'))));
    });

    test('a successful sign-in resets the failure count', () async {
      await fail(distroEmail, 2);
      await b.signIn(distroEmail, distroPw);
      await b.signOut();
      // Two more failures must NOT lock (count restarted at 0).
      await fail(distroEmail, 2);
      expect((await b.signIn(distroEmail, distroPw)).name, 'Derrick Distributor');
    });

    test('lockout raises a manager alert; renewing the password clears lock + alert',
        () async {
      await fail(distroEmail, 3);

      await b.signIn(mgrEmail, mgrPw);
      final alerts = await b.alerts();
      expect(alerts.length, 1);
      expect(alerts.single.userName, 'Derrick Distributor');

      final newPw = await b.resendCredentials(alerts.single.userId);
      expect(newPw, isNotNull);
      expect(await b.alerts(), isEmpty);
      await b.signOut();

      // Still inside the 10 seconds, but the renewal lifted the lock.
      expect((await b.signIn(distroEmail, newPw!)).name, 'Derrick Distributor');
    });

    test('only managers can see or dismiss alerts', () async {
      await fail(mgrEmail, 3);
      await b.signIn(distroEmail, distroPw);
      await expectLater(b.alerts(), throwsA(isA<BackendException>()));
    });

    test('unknown emails do not lock or create alerts', () async {
      await fail('nobody@potie.app', 5);
      await b.signIn(mgrEmail, mgrPw);
      expect(await b.alerts(), isEmpty);
    });
  });

  test('roles are enforced', () async {
    final b = DemoBackend();
    await b.signIn(distroEmail, distroPw);
    await expectLater(
        b.daySummary(DateTime.now()), throwsA(isA<BackendException>()));
    await b.signIn(mgrEmail, mgrPw);
    await expectLater(b.registerWaiter('Nope'), throwsA(isA<BackendException>()));
  });
}
