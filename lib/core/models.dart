/// Staff who sign in. Waiters are not users: the distributor registers them
/// ([Waiter]) and they have no access to the app.
enum Role { manager, distributor }

enum PayMethod { mobileMoney, cash, visa }

/// When the customer pays for a pot. Anything but [immediate] must be settled
/// within [payWindow] of the pot going out.
enum PayTiming { immediate, onReturn, later }

const payWindow = Duration(hours: 12);

extension PayTimingX on PayTiming {
  String get label => switch (this) {
        PayTiming.immediate => 'Pay now',
        PayTiming.onReturn => 'Pay on return',
        PayTiming.later => 'Pay later',
      };
  String get wire => switch (this) {
        PayTiming.immediate => 'immediate',
        PayTiming.onReturn => 'on_return',
        PayTiming.later => 'later',
      };
  static PayTiming parse(String? s) => PayTiming.values
      .firstWhere((m) => m.wire == s, orElse: () => PayTiming.immediate);
}

extension PayMethodX on PayMethod {
  String get label => switch (this) {
        PayMethod.mobileMoney => 'Mobile Money',
        PayMethod.cash => 'Cash',
        PayMethod.visa => 'Visa',
      };
  String get wire => switch (this) {
        PayMethod.mobileMoney => 'mobile_money',
        PayMethod.cash => 'cash',
        PayMethod.visa => 'visa',
      };
  static PayMethod parse(String s) =>
      PayMethod.values.firstWhere((m) => m.wire == s);
}

extension RoleX on Role {
  String get label => switch (this) {
        Role.manager => 'Manager',
        Role.distributor => 'Distributor',
      };
  static Role parse(String s) => Role.values.firstWhere((r) => r.name == s);
}

/// out       -> pot is with the waiter/customer, timer running
/// returned  -> pot back with the distributor
/// (`issued` is legacy and no longer produced.)
enum TokenStatus { issued, out, returned }

/// Result of enrolling someone: the account and the temporary password, which
/// the manager hands over (email app, WhatsApp, SMS...) - it works without the
/// server's own email being set up.
class EnrollResult {
  final AppUser user;
  final String? tempPassword;
  const EnrollResult(this.user, {this.tempPassword});
}

class AppUser {
  final String id;
  final String name;
  final String email;
  final Role role;
  final bool active;

  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.active = true,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'].toString(),
        name: j['name'] as String,
        email: j['email'] as String,
        role: RoleX.parse(j['role'] as String),
        active: j['active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'role': role.name,
        'active': active,
      };
}

/// A waiter registered by the distributor (no login).
class Waiter {
  final String id;
  final String name;
  final bool active;

  const Waiter({required this.id, required this.name, this.active = true});

  factory Waiter.fromJson(Map<String, dynamic> j) => Waiter(
        id: j['id'].toString(),
        name: j['name'] as String,
        active: j['active'] as bool? ?? true,
      );
}

class Pot {
  final String id;

  /// Random unique tracking number, e.g. "P-4821".
  final String label;

  /// Retired pots are kept for the audit trail but can't be issued.
  final bool active;

  /// Currently with a customer.
  final bool out;

  const Pot({
    required this.id,
    required this.label,
    this.active = true,
    this.out = false,
  });

  bool get available => active && !out;

  factory Pot.fromJson(Map<String, dynamic> j) => Pot(
        id: j['id'].toString(),
        label: j['label'] as String,
        active: j['active'] as bool? ?? true,
        out: j['out'] as bool? ?? false,
      );
}

class Extension {
  final String id;
  final int minutes;
  final double fee;
  final PayMethod method;
  final DateTime at;
  final bool confirmed;

  const Extension({
    required this.id,
    required this.minutes,
    required this.fee,
    required this.method,
    required this.at,
    required this.confirmed,
  });

  factory Extension.fromJson(Map<String, dynamic> j) => Extension(
        id: j['id'].toString(),
        minutes: j['minutes'] as int,
        fee: (j['fee'] as num).toDouble(),
        method: PayMethodX.parse(j['method'] as String),
        at: DateTime.parse(j['at'] as String).toLocal(),
        confirmed: j['confirmed'] as bool,
      );
}

class PotToken {
  final String id;
  final String code;
  final String waiterId;
  final String waiterName;
  final int minutes;
  final double amount;
  final PayMethod method;
  final DateTime issuedAt;
  final TokenStatus status;
  final String? distributorId;
  final String? distributorName;
  final String? potLabel;
  final DateTime? clearedAt;
  final DateTime? returnedAt;
  final bool paymentConfirmed;
  final PayTiming payTiming;
  final DateTime? paidAt;

  /// Deadline for an unpaid token (issue time + 12 h).
  final DateTime? payDueAt;
  final List<Extension> extensions;

  const PotToken({
    required this.id,
    required this.code,
    required this.waiterId,
    required this.waiterName,
    required this.minutes,
    required this.amount,
    required this.method,
    required this.issuedAt,
    required this.status,
    this.distributorId,
    this.distributorName,
    this.potLabel,
    this.clearedAt,
    this.returnedAt,
    this.paymentConfirmed = false,
    this.payTiming = PayTiming.immediate,
    this.paidAt,
    this.payDueAt,
    this.extensions = const [],
  });

  bool get paid => paymentConfirmed;

  /// Unpaid and past the 12 hour limit.
  bool get paymentOverdue =>
      !paid && payDueAt != null && DateTime.now().isAfter(payDueAt!);

  /// Money actually received so far (the token price only once it is paid).
  double get collected =>
      (paid ? amount : 0.0) +
      extensions.where((e) => e.confirmed).fold(0.0, (s, e) => s + e.fee);

  /// Token price still to be collected.
  double get outstanding => paid ? 0.0 : amount;

  int get totalMinutes => minutes + extensions.fold(0, (s, e) => s + e.minutes);
  double get totalFees => amount + extensions.fold(0.0, (s, e) => s + e.fee);

  DateTime? get dueAt =>
      clearedAt?.add(Duration(minutes: totalMinutes));

  Duration? get remaining {
    final d = dueAt;
    if (d == null || status != TokenStatus.out) return null;
    return d.difference(DateTime.now());
  }

  bool get overdue => (remaining ?? const Duration(seconds: 1)).isNegative;

  factory PotToken.fromJson(Map<String, dynamic> j) {
    DateTime? d(String k) =>
        j[k] == null ? null : DateTime.parse(j[k] as String).toLocal();
    return PotToken(
      id: j['id'].toString(),
      code: j['code'] as String,
      waiterId: j['waiter_id'].toString(),
      waiterName: j['waiter_name'] as String,
      minutes: j['minutes'] as int,
      amount: (j['amount'] as num).toDouble(),
      method: PayMethodX.parse(j['method'] as String),
      issuedAt: d('issued_at')!,
      status: TokenStatus.values.byName(j['status'] as String),
      distributorId: j['distributor_id']?.toString(),
      distributorName: j['distributor_name'] as String?,
      potLabel: j['pot_label'] as String?,
      clearedAt: d('cleared_at'),
      returnedAt: d('returned_at'),
      paymentConfirmed: j['payment_confirmed'] as bool? ?? false,
      payTiming: PayTimingX.parse(j['pay_timing'] as String?),
      paidAt: d('paid_at'),
      payDueAt: d('pay_due_at'),
      extensions: ((j['extensions'] as List?) ?? const [])
          .map((e) => Extension.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  PotToken copyWith({
    PayMethod? method,
    DateTime? paidAt,
    TokenStatus? status,
    String? distributorId,
    String? distributorName,
    String? potLabel,
    DateTime? clearedAt,
    DateTime? returnedAt,
    bool? paymentConfirmed,
    List<Extension>? extensions,
  }) =>
      PotToken(
        id: id,
        code: code,
        waiterId: waiterId,
        waiterName: waiterName,
        minutes: minutes,
        amount: amount,
        method: method ?? this.method,
        issuedAt: issuedAt,
        status: status ?? this.status,
        distributorId: distributorId ?? this.distributorId,
        distributorName: distributorName ?? this.distributorName,
        potLabel: potLabel ?? this.potLabel,
        clearedAt: clearedAt ?? this.clearedAt,
        returnedAt: returnedAt ?? this.returnedAt,
        paymentConfirmed: paymentConfirmed ?? this.paymentConfirmed,
        payTiming: payTiming,
        paidAt: paidAt ?? this.paidAt,
        payDueAt: payDueAt,
        extensions: extensions ?? this.extensions,
      );
}

class AuditEntry {
  final String id;
  final DateTime at;
  final String actorName;
  final Role actorRole;
  final String action;
  final String detail;

  const AuditEntry({
    required this.id,
    required this.at,
    required this.actorName,
    required this.actorRole,
    required this.action,
    required this.detail,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: j['id'].toString(),
        at: DateTime.parse(j['at'] as String).toLocal(),
        actorName: j['actor_name'] as String,
        actorRole: RoleX.parse(j['actor_role'] as String),
        action: j['action'] as String,
        detail: j['detail'] as String,
      );
}

/// Raised for the manager when a user is locked out of signing in.
class SecurityAlert {
  final String id;
  final String userId;
  final String userName;
  final String userEmail;
  final Role userRole;
  final String message;
  final DateTime at;

  const SecurityAlert({
    required this.id,
    required this.userId,
    required this.userName,
    required this.userEmail,
    required this.userRole,
    required this.message,
    required this.at,
  });

  factory SecurityAlert.fromJson(Map<String, dynamic> j) => SecurityAlert(
        id: j['id'].toString(),
        userId: j['user_id'].toString(),
        userName: j['user_name'] as String,
        userEmail: j['user_email'] as String,
        userRole: RoleX.parse(j['user_role'] as String),
        message: j['message'] as String,
        at: DateTime.parse(j['at'] as String).toLocal(),
      );
}

class SmtpConfig {
  final String host;
  final int port;
  final bool secure;
  final String username;
  final String password;
  final String fromName;
  final String fromEmail;

  const SmtpConfig({
    this.host = '',
    this.port = 587,
    this.secure = false,
    this.username = '',
    this.password = '',
    this.fromName = 'Arrows Bar',
    this.fromEmail = '',
  });

  factory SmtpConfig.fromJson(Map<String, dynamic> j) => SmtpConfig(
        host: j['host'] as String? ?? '',
        port: j['port'] as int? ?? 587,
        secure: j['secure'] as bool? ?? false,
        username: j['username'] as String? ?? '',
        password: j['password'] as String? ?? '',
        fromName: j['from_name'] as String? ?? 'Arrows Bar',
        fromEmail: j['from_email'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'secure': secure,
        'username': username,
        'password': password,
        'from_name': fromName,
        'from_email': fromEmail,
      };
}

class DaySummary {
  final DateTime day;
  final List<PotToken> tokens;
  final List<AuditEntry> audit;
  const DaySummary(
      {required this.day, required this.tokens, required this.audit});

  /// Waiters that issued at least one token that day.
  List<String> get waiters =>
      tokens.map((t) => t.waiterName).toSet().toList()..sort();

  double totalFor(PayMethod m) {
    var s = 0.0;
    for (final t in tokens) {
      if (t.method == m && t.paid) s += t.amount;
      for (final e in t.extensions) {
        if (e.method == m && e.confirmed) s += e.fee;
      }
    }
    return s;
  }

  /// Token prices not yet collected.
  double get outstanding => tokens.fold(0.0, (s, t) => s + t.outstanding);

  double get total => PayMethod.values.fold(0.0, (s, m) => s + totalFor(m));
}
