import '../core/models.dart';

/// Everything the UI needs from the server. Two implementations:
///  * [HttpBackend]  – Supabase Auth + REST API backed by PostgreSQL
abstract class Backend {
  Future<AppUser> signIn(String email, String password);
  Future<void> signOut();
  Future<AppUser?> restore();
  Future<void> sendPasswordReset(String email);

  // Own profile (every role)
  Future<AppUser> updateProfile({required String name, required String email});
  Future<void> changePassword({
    required String current,
    required String newPassword,
  });

  // Distributor (the only role that handles tokens, pots and waiters)

  /// Waiters are registered by the distributor and have no login.
  /// [all] also returns retired waiters.
  Future<List<Waiter>> waiters({bool all = false});
  Future<Waiter> registerWaiter(String name);
  Future<Waiter> updateWaiter(String waiterId, {String? name, bool? active});

  Future<List<Pot>> availablePots();
  Future<List<Pot>> allPots();

  /// Registers [count] new pots; each gets a random unique tracking number.
  Future<List<Pot>> registerPots(int count);
  Future<void> setPotActive(String potId, bool active);

  /// Issues a pot to a waiter: creates the token and starts the timer.
  /// With [PayTiming.immediate] the payment is recorded now using [method];
  /// otherwise it stays unpaid (due within 12 h) until [settlePayment].
  Future<PotToken> issueToken({
    required String waiterId,
    required String potId,
    required int minutes,
    required double amount,
    required PayMethod method,
    PayTiming timing = PayTiming.immediate,
  });

  /// Records the payment of a token that was not paid when the pot went out.
  Future<PotToken> settlePayment(String tokenId, PayMethod method);

  /// Tokens still waiting for payment (any status), earliest deadline first.
  Future<List<PotToken>> unpaidTokens();
  Future<PotToken> extendToken({
    required String tokenId,
    required int minutes,
    required double fee,
    required PayMethod method,
  });

  /// The waiter has brought the pot back; records it as returned.
  Future<PotToken> returnPot(String tokenId);
  Future<List<PotToken>> activeTokens();

  // Manager
  Future<DaySummary> daySummary(DateTime day);
  Future<List<PotToken>> tokensBetween(DateTime from, DateTime to);
  Future<List<AuditEntry>> auditBetween(DateTime from, DateTime to);
  Future<List<AppUser>> users();
  Future<EnrollResult> enrollUser({
    required String name,
    required String email,
    required Role role,
  });
  Future<void> setUserActive(String userId, bool active);
  Future<AppUser> editUser(String userId,
      {required String name, required String email});
  /// Sets a new temporary password, emails it, lifts any lockout and closes
  /// the user's alerts. Returns the new password so the manager can hand it over.
  Future<String?> resendCredentials(String userId);

  // Lockout alerts
  Future<List<SecurityAlert>> alerts();
  Future<void> dismissAlert(String alertId);
  Future<SmtpConfig> getSmtp();
  Future<void> saveSmtp(SmtpConfig cfg);
  Future<void> testSmtp(String toEmail);
}

class BackendException implements Exception {
  final String message;

  /// Set when sign-in is locked: when the user may try again.
  final DateTime? lockedUntil;

  /// HTTP status when the error came from the API (401 = session no longer valid).
  final int? status;
  BackendException(this.message, {this.lockedUntil, this.status});
  @override
  String toString() => message;
}
