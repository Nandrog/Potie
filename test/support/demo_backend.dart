import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:potie/core/models.dart';
import 'package:potie/data/backend.dart';

/// In-memory backend with seeded data. Lets the whole app be explored before
/// a server. Used by the tests only; the app itself always uses the real API.
class DemoBackend implements Backend {
  /// [clock] lets tests move time forward to check the lockout expiry.
  DemoBackend({DateTime Function()? clock}) : _now = clock ?? DateTime.now {
    _seed();
  }

  static const maxAttempts = 3;
  static const lockSeconds = 10;

  final DateTime Function() _now;
  final Map<String, int> _failed = {}; // by user id
  final Map<String, DateTime> _lockedUntil = {}; // by user id
  final List<SecurityAlert> _alerts = [];

  final _rng = Random.secure();
  AppUser? _me;
  int _seq = 100;
  SmtpConfig _smtp = const SmtpConfig();

  final Map<String, String> _passwords = {};
  final List<AppUser> _users = [];
  final List<Waiter> _waiters = [];
  final List<Pot> _pots = [];
  final List<PotToken> _tokens = [];
  final List<AuditEntry> _audit = [];

  void _seed() {
    void user(String id, String name, String email, Role r, String pw) {
      _users.add(AppUser(id: id, name: name, email: email, role: r));
      _passwords[email] = pw;
    }

    user('m1', 'Maria Manager', 'manager@potie.app', Role.manager, 'Manager@123');
    user('d1', 'Derrick Distributor', 'distributor@potie.app', Role.distributor,
        'Distro@123');

    _waiters.addAll(const [
      Waiter(id: 'w1', name: 'Wanda Waiter'),
      Waiter(id: 'w2', name: 'Wilson Waiter'),
    ]);

    for (var i = 0; i < 12; i++) {
      _pots.add(Pot(id: 'p${_seq++}', label: _newPotLabel()));
    }
    final outPot = _pots[2].label, backPot = _pots[6].label;

    // A little history so the manager dashboard is not empty.
    final now = DateTime.now();
    final w1 = _waiters[0], w2 = _waiters[1], d1 = _users[1];
    _tokens.add(PotToken(
      id: 't1',
      code: '482915',
      waiterId: w1.id,
      waiterName: w1.name,
      minutes: 60,
      amount: 50000,
      method: PayMethod.mobileMoney,
      issuedAt: now.subtract(const Duration(minutes: 80)),
      status: TokenStatus.out,
      distributorId: d1.id,
      distributorName: d1.name,
      potLabel: outPot,
      clearedAt: now.subtract(const Duration(minutes: 80)),
      paymentConfirmed: true,
    ));
    _tokens.add(PotToken(
      id: 't2',
      code: '730164',
      waiterId: w2.id,
      waiterName: w2.name,
      minutes: 45,
      amount: 40000,
      method: PayMethod.cash,
      issuedAt: now.subtract(const Duration(hours: 3)),
      status: TokenStatus.returned,
      distributorId: d1.id,
      distributorName: d1.name,
      potLabel: backPot,
      clearedAt: now.subtract(const Duration(hours: 3)),
      returnedAt: now.subtract(const Duration(hours: 2)),
      paymentConfirmed: true,
    ));
    _log(d1, 'POT_OUT',
        '$outPot to ${w1.name} · 60 min · 50,000 · Mobile Money',
        at: now.subtract(const Duration(minutes: 80)));
  }

  AppUser get _actor {
    final me = _me;
    if (me == null) throw BackendException('Not signed in.');
    return me;
  }

  void _log(AppUser a, String action, String detail, {DateTime? at}) {
    _audit.add(AuditEntry(
      id: '${_seq++}',
      at: at ?? DateTime.now(),
      actorName: a.name,
      actorRole: a.role,
      action: action,
      detail: detail,
    ));
  }

  void _need(Role r) {
    if (_actor.role != r) throw BackendException('Not allowed for your role.');
  }

  PotToken _find(String id) => _tokens.firstWhere((t) => t.id == id,
      orElse: () => throw BackendException('Token not found.'));

  void _put(PotToken t) {
    final i = _tokens.indexWhere((x) => x.id == t.id);
    _tokens[i] = t;
  }

  String _fmt(double v) => v.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  // ---- auth
  @override
  Future<AppUser> signIn(String email, String password) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final e = email.trim().toLowerCase();
    final u = _users.where((u) => u.email == e).firstOrNull;
    if (u == null) throw BackendException('Wrong email or password.');

    final until = _lockedUntil[u.id];
    if (until != null && until.isAfter(_now())) throw _locked(until);
    if (!u.active) throw BackendException('This account has been disabled.');

    if (_passwords[e] != password) {
      final n = (_failed[u.id] ?? 0) + 1;
      if (n >= maxAttempts) throw _locked(_lock(u));
      _failed[u.id] = n;
      final left = maxAttempts - n;
      throw BackendException(
          'Wrong email or password. $left attempt${left == 1 ? '' : 's'} left.');
    }
    _failed.remove(u.id);
    _lockedUntil.remove(u.id);
    _saveLogin(u.email);
    return _me = u;
  }

  static const _kDemoUser = 'demo_signed_in_email';

  // Remembered so a browser refresh does not drop the user back to the login page.
  Future<void> _saveLogin(String? email) async {
    try {
      final p = await SharedPreferences.getInstance();
      email == null ? await p.remove(_kDemoUser) : await p.setString(_kDemoUser, email);
    } catch (_) {/* no storage (e.g. unit tests) */}
  }

  BackendException _locked(DateTime until) {
    final secs =
        until.difference(_now()).inSeconds.clamp(1, lockSeconds).toInt();
    return BackendException(
        'Too many failed attempts. Try again in $secs second${secs == 1 ? '' : 's'}.',
        lockedUntil: until);
  }

  DateTime _lock(AppUser u) {
    final until = _now().add(const Duration(seconds: lockSeconds));
    _lockedUntil[u.id] = until;
    _failed[u.id] = 0;
    _alerts.removeWhere((a) => a.userId == u.id); // one open alert per user
    _alerts.insert(
      0,
      SecurityAlert(
        id: 'a${_seq++}',
        userId: u.id,
        userName: u.name,
        userEmail: u.email,
        userRole: u.role,
        message:
            '${u.name} (${u.role.label}) was locked out for $lockSeconds seconds after '
            '$maxAttempts failed sign-in attempts. If it was not them, renew their password.',
        at: _now(),
      ),
    );
    _log(u, 'ACCOUNT_LOCKED',
        '${u.name} locked for $lockSeconds s after $maxAttempts failed sign-ins');
    return until;
  }

  @override
  Future<AppUser?> restore() async {
    if (_me != null) return _me;
    try {
      final email = (await SharedPreferences.getInstance()).getString(_kDemoUser);
      if (email != null) {
        _me = _users.where((u) => u.email == email && u.active).firstOrNull;
      }
    } catch (_) {}
    return _me;
  }

  @override
  Future<void> signOut() async {
    _me = null;
    await _saveLogin(null);
  }

  @override
  Future<void> sendPasswordReset(String email) async {}

  // ---- profile
  AppUser _rename(String id, String name, String email) {
    final n = name.trim(), e = email.trim().toLowerCase();
    if (n.isEmpty) throw BackendException('Name is required.');
    if (!e.contains('@')) throw BackendException('Enter a valid email.');
    final i = _users.indexWhere((u) => u.id == id);
    final old = _users[i];
    if (e != old.email && _users.any((u) => u.email == e)) {
      throw BackendException('A user with that email already exists.');
    }
    final u = AppUser(
        id: old.id, name: n, email: e, role: old.role, active: old.active);
    _users[i] = u;
    if (e != old.email) _passwords[e] = _passwords.remove(old.email)!;
    return u;
  }

  @override
  Future<AppUser> updateProfile(
      {required String name, required String email}) async {
    final u = _rename(_actor.id, name, email);
    _me = u;
    _log(u, 'PROFILE_UPDATED', 'Updated own name/email');
    return u;
  }

  @override
  Future<void> changePassword(
      {required String current, required String newPassword}) async {
    if (_passwords[_actor.email] != current) {
      throw BackendException('Current password is incorrect.');
    }
    if (newPassword.length < 8) {
      throw BackendException('New password must be at least 8 characters.');
    }
    _passwords[_actor.email] = newPassword;
    _log(_actor, 'PASSWORD_CHANGED', 'Changed own password');
  }

  // ---- distributor
  String _newCode() {
    String code;
    do {
      code = (100000 + _rng.nextInt(900000)).toString();
    } while (_tokens.any((t) => t.code == code));
    return code;
  }

  @override
  Future<List<Waiter>> waiters({bool all = false}) async {
    if (_actor.role != Role.distributor && _actor.role != Role.manager) {
      throw BackendException('Not allowed for your role.');
    }
    final l = _waiters.where((w) => all || w.active).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return l;
  }

  @override
  Future<Waiter> registerWaiter(String name) async {
    _need(Role.distributor);
    final n = name.trim();
    if (n.isEmpty) throw BackendException('Enter the waiter name.');
    final w = Waiter(id: 'w${_seq++}', name: n);
    _waiters.add(w);
    _log(_actor, 'WAITER_REGISTERED', '$n registered as a waiter');
    return w;
  }

  @override
  Future<Waiter> updateWaiter(String waiterId,
      {String? name, bool? active}) async {
    _need(Role.distributor);
    final i = _waiters.indexWhere((w) => w.id == waiterId);
    if (i < 0) throw BackendException('Waiter not found.');
    final cur = _waiters[i];
    final n = name?.trim();
    if (n != null && n.isEmpty) throw BackendException('Name is required.');
    if (active == false &&
        _tokens.any((t) => t.waiterId == cur.id && t.status == TokenStatus.out)) {
      throw BackendException(
          '${cur.name} still has a pot out. Retire them after it is returned.');
    }
    final u = Waiter(
        id: cur.id, name: n ?? cur.name, active: active ?? cur.active);
    _waiters[i] = u;
    _log(
        _actor,
        'WAITER_UPDATED',
        n != null && n != cur.name
            ? '${cur.name} renamed to $n'
            : active == false
                ? '${cur.name} retired'
                : active == true
                    ? '${cur.name} restored'
                    : '${cur.name} updated');
    return u;
  }

  Set<String?> get _busyLabels => _tokens
      .where((t) => t.status == TokenStatus.out)
      .map((t) => t.potLabel)
      .toSet();

  /// Random 4-digit tracking number, unique across every pot ever registered.
  String _newPotLabel() {
    String l;
    do {
      l = 'P-${1000 + _rng.nextInt(9000)}';
    } while (_pots.any((p) => p.label == l));
    return l;
  }

  @override
  Future<List<Pot>> allPots() async {
    _actor; // must be signed in (distributor and manager may view pots)
    final busy = _busyLabels;
    return [
      for (final p in _pots)
        Pot(id: p.id, label: p.label, active: p.active, out: busy.contains(p.label))
    ]..sort((a, b) => a.label.compareTo(b.label));
  }

  @override
  Future<List<Pot>> availablePots() async =>
      (await allPots()).where((p) => p.available).toList();

  @override
  Future<List<Pot>> registerPots(int count) async {
    _need(Role.distributor);
    if (count < 1 || count > 100) {
      throw BackendException('Register between 1 and 100 pots at a time.');
    }
    final made = [
      for (var i = 0; i < count; i++)
        () {
          final p = Pot(id: 'p${_seq++}', label: _newPotLabel());
          _pots.add(p);
          return p;
        }()
    ];
    _log(_actor, 'POTS_REGISTERED',
        '$count pot(s) registered: ${made.map((p) => p.label).join(', ')}');
    return made;
  }

  @override
  Future<void> setPotActive(String potId, bool active) async {
    _need(Role.distributor);
    final i = _pots.indexWhere((p) => p.id == potId);
    if (i < 0) throw BackendException('Pot not found.');
    final p = _pots[i];
    if (!active && _busyLabels.contains(p.label)) {
      throw BackendException('${p.label} is out. Retire it after it is returned.');
    }
    _pots[i] = Pot(id: p.id, label: p.label, active: active);
    _log(_actor, active ? 'POT_RESTORED' : 'POT_RETIRED', p.label);
  }

  @override
  Future<PotToken> issueToken(
      {required String waiterId,
      required String potId,
      required int minutes,
      required double amount,
      required PayMethod method,
      PayTiming timing = PayTiming.immediate}) async {
    _need(Role.distributor);
    if (minutes <= 0 || amount <= 0) {
      throw BackendException('Time and amount must be greater than zero.');
    }
    final pot = _pots.firstWhere((p) => p.id == potId,
        orElse: () => throw BackendException('Unknown pot.'));
    if (!pot.active) throw BackendException('${pot.label} is retired.');
    if (_busyLabels.contains(pot.label)) {
      throw BackendException('${pot.label} is already out.');
    }
    final waiter = _waiters.where((w) => w.id == waiterId && w.active).firstOrNull;
    if (waiter == null) throw BackendException('Unknown waiter.');
    final now = DateTime.now();
    final t = PotToken(
      id: 't${_seq++}',
      code: _newCode(),
      waiterId: waiter.id,
      waiterName: waiter.name,
      minutes: minutes,
      amount: amount,
      method: method,
      issuedAt: now,
      status: TokenStatus.out,
      distributorId: _actor.id,
      distributorName: _actor.name,
      potLabel: pot.label,
      clearedAt: now,
      paymentConfirmed: timing == PayTiming.immediate,
      payTiming: timing,
      paidAt: timing == PayTiming.immediate ? now : null,
      payDueAt: timing == PayTiming.immediate ? null : now.add(payWindow),
    );
    _tokens.add(t);
    _log(
        _actor,
        'POT_OUT',
        '${pot.label} to ${waiter.name} · $minutes min · ${_fmt(amount)} · '
        '${timing == PayTiming.immediate ? method.label : 'UNPAID (${timing.label.toLowerCase()}, within 12 h)'}');
    return t;
  }

  @override
  Future<PotToken> settlePayment(String tokenId, PayMethod method) async {
    _need(Role.distributor);
    final t = _find(tokenId);
    if (t.paid) throw BackendException('This token is already paid.');
    final late = t.paymentOverdue ? ' (after the 12 h limit)' : '';
    final u = t.copyWith(
        method: method, paymentConfirmed: true, paidAt: DateTime.now());
    _put(u);
    _log(_actor, 'PAYMENT_RECEIVED',
        '${t.potLabel} · ${t.waiterName} paid ${_fmt(t.amount)} by ${method.label}$late');
    return u;
  }

  @override
  Future<List<PotToken>> unpaidTokens() async {
    _actor;
    return _tokens.where((t) => !t.paid).toList()
      ..sort((a, b) => a.payDueAt!.compareTo(b.payDueAt!));
  }

  @override
  Future<PotToken> extendToken(
      {required String tokenId,
      required int minutes,
      required double fee,
      required PayMethod method}) async {
    _need(Role.distributor);
    final t = _find(tokenId);
    if (t.status != TokenStatus.out) {
      throw BackendException('Only pots that are out can be extended.');
    }
    if (minutes <= 0 || fee <= 0) {
      throw BackendException('Time and fee must be greater than zero.');
    }
    final ext = Extension(
        id: 'e${_seq++}',
        minutes: minutes,
        fee: fee,
        method: method,
        at: DateTime.now(),
        confirmed: true);
    final u = t.copyWith(extensions: [...t.extensions, ext]);
    _put(u);
    _log(_actor, 'EXTENDED',
        '${t.potLabel} +$minutes min · ${_fmt(fee)} · ${method.label}');
    return u;
  }

  @override
  Future<PotToken> returnPot(String tokenId) async {
    _need(Role.distributor);
    final t = _find(tokenId);
    if (t.status != TokenStatus.out) {
      throw BackendException('This pot is not out.');
    }
    final u = t.copyWith(status: TokenStatus.returned, returnedAt: DateTime.now());
    _put(u);
    _log(_actor, 'POT_RETURNED', '${t.potLabel} returned by ${t.waiterName}');
    return u;
  }

  @override
  Future<List<PotToken>> activeTokens() async =>
      _tokens.where((t) => t.status == TokenStatus.out).toList();

  // ---- manager
  bool _in(DateTime x, DateTime from, DateTime to) =>
      !x.isBefore(from) && x.isBefore(to);

  @override
  Future<DaySummary> daySummary(DateTime day) async {
    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1));
    return DaySummary(
        day: from,
        tokens: await tokensBetween(from, to),
        audit: await auditBetween(from, to));
  }

  @override
  Future<List<PotToken>> tokensBetween(DateTime from, DateTime to) async {
    _need(Role.manager);
    return _tokens.where((t) => _in(t.issuedAt, from, to)).toList();
  }

  @override
  Future<List<AuditEntry>> auditBetween(DateTime from, DateTime to) async {
    _need(Role.manager);
    return _audit.where((a) => _in(a.at, from, to)).toList().reversed.toList();
  }

  @override
  Future<List<AppUser>> users() async => List.of(_users);

  @override
  Future<EnrollResult> enrollUser(
      {required String name, required String email, required Role role}) async {
    _need(Role.manager);
    final e = email.trim().toLowerCase();
    if (_users.any((u) => u.email == e)) {
      throw BackendException('A user with that email already exists.');
    }
    final u = AppUser(id: 'u${_seq++}', name: name.trim(), email: e, role: role);
    _users.add(u);
    final pw = 'Temp#${_rng.nextInt(9000) + 1000}';
    _passwords[e] = pw;
    _log(_actor, 'USER_ENROLLED', '${u.name} (${role.label}) enrolled');
    return EnrollResult(u, tempPassword: pw);
  }

  @override
  Future<void> setUserActive(String userId, bool active) async {
    _need(Role.manager);
    final i = _users.indexWhere((u) => u.id == userId);
    final u = _users[i];
    _users[i] = AppUser(
        id: u.id, name: u.name, email: u.email, role: u.role, active: active);
    if (active) {
      _failed.remove(u.id);
      _lockedUntil.remove(u.id);
    }
    _log(_actor, active ? 'USER_ENABLED' : 'USER_DISABLED', u.name);
  }

  @override
  Future<AppUser> editUser(String userId,
      {required String name, required String email}) async {
    _need(Role.manager);
    final u = _rename(userId, name, email);
    _log(_actor, 'USER_EDITED', 'Updated details for ${u.name}');
    return u;
  }

  @override
  Future<String?> resendCredentials(String userId) async {
    _need(Role.manager);
    final u = _users.firstWhere((u) => u.id == userId,
        orElse: () => throw BackendException('User not found.'));
    // Demo can't send real email, so the new password is returned to be shown.
    final pw = 'Temp#${_rng.nextInt(9000) + 1000}';
    _passwords[u.email] = pw;
    _failed.remove(u.id);
    _lockedUntil.remove(u.id);
    _alerts.removeWhere((a) => a.userId == u.id);
    _log(_actor, 'CREDENTIALS_SENT', 'New login details emailed to ${u.name}');
    return pw;
  }

  @override
  Future<List<SecurityAlert>> alerts() async {
    _need(Role.manager);
    return List.of(_alerts);
  }

  @override
  Future<void> dismissAlert(String alertId) async {
    _need(Role.manager);
    _alerts.removeWhere((a) => a.id == alertId);
  }

  @override
  Future<SmtpConfig> getSmtp() async => _smtp;

  @override
  Future<void> saveSmtp(SmtpConfig cfg) async {
    _need(Role.manager);
    _smtp = cfg;
    _log(_actor, 'SMTP_UPDATED', 'SMTP host ${cfg.host}:${cfg.port}');
  }

  @override
  Future<void> testSmtp(String toEmail) async {
    if (_smtp.host.isEmpty) throw BackendException('Save the SMTP settings first.');
    throw BackendException('Demo mode cannot send real email.');
  }
}
