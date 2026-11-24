import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/models.dart';
import 'backend.dart';
import 'resilient_http.dart';

/// Talks to the Node/Prisma API in /server. Authentication is Supabase Auth;
/// every request carries the Supabase access token which the server verifies.
class HttpBackend implements Backend {
  HttpBackend(this.baseUrl);
  final String baseUrl;

  /// Falls back to a public DNS lookup on networks that can't find the server.
  final http.Client _http = createApiClient();
  GoTrueClient get _auth => Supabase.instance.client.auth;

  Future<Map<String, String>> _headers() async {
    final token = _auth.currentSession?.accessToken;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<dynamic> _send(String method, String path,
      {Map<String, dynamic>? body,
      Map<String, String>? query,
      bool retried = false}) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final headers = await _headers();
    final http.Response res;
    try {
      // The free host sleeps when idle and takes up to ~1 minute to wake, so
      // allow that long and try a second time if the first connection drops.
      Future<http.Response> once() {
        final f = switch (method) {
          'GET' => _http.get(uri, headers: headers),
          'POST' => _http.post(uri, headers: headers, body: jsonEncode(body ?? {})),
          'PUT' => _http.put(uri, headers: headers, body: jsonEncode(body ?? {})),
          'PATCH' => _http.patch(uri, headers: headers, body: jsonEncode(body ?? {})),
          'DELETE' => _http.delete(uri, headers: headers),
          _ => throw ArgumentError(method),
        };
        return f.timeout(const Duration(seconds: 75));
      }

      res = await () async {
        try {
          return await once();
        } on http.ClientException {
          await Future<void>.delayed(const Duration(seconds: 3));
          return await once();
        }
      }();
    } on TimeoutException {
      throw BackendException(
          'The server is taking too long to answer (it may be waking up). Wait a minute and try again.');
    } on http.ClientException {
      throw BackendException('Cannot reach the server. Check your internet connection.');
    }
    // The access token may have expired while the app sat idle: refresh once and retry.
    if (res.statusCode == 401 && !retried && _auth.currentSession != null) {
      try {
        await _auth.refreshSession();
        return await _send(method, path, body: body, query: query, retried: true);
      } catch (_) {/* fall through to the normal 401 error */}
    }
    final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode >= 400) {
      final secs = decoded is Map ? decoded['retry_after_seconds'] : null;
      throw BackendException(
        (decoded is Map ? decoded['error'] : null)?.toString() ??
            'Request failed (${res.statusCode})',
        lockedUntil:
            secs is int ? DateTime.now().add(Duration(seconds: secs)) : null,
        status: res.statusCode,
      );
    }
    return decoded;
  }

  Future<dynamic> _get(String p, [Map<String, String>? q]) =>
      _send('GET', p, query: q);
  Future<dynamic> _post(String p, [Map<String, dynamic>? b]) =>
      _send('POST', p, body: b);

  PotToken _token(dynamic j) => PotToken.fromJson(j as Map<String, dynamic>);
  List<PotToken> _tokens(dynamic j) => (j as List).map(_token).toList();

  // ---- auth
  @override
  Future<AppUser> signIn(String email, String password) async {
    // Sign in through our API so failed attempts are counted and the account
    // is locked after three (see server /auth/login), then hand the resulting
    // session to the Supabase client.
    final r = await _post('/auth/login', {'email': email.trim(), 'password': password})
        as Map<String, dynamic>;
    try {
      await _auth.setSession(r['refresh_token'] as String);
    } on AuthException catch (e) {
      throw BackendException(e.message);
    }
    return _remember(
        AppUser.fromJson(await _get('/me') as Map<String, dynamic>));
  }

  static const _kUser = 'signed_in_user';

  Future<AppUser> _remember(AppUser u) async {
    try {
      (await SharedPreferences.getInstance())
          .setString(_kUser, jsonEncode(u.toJson()));
    } catch (_) {}
    return u;
  }

  Future<AppUser?> _remembered() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(_kUser);
      return s == null
          ? null
          : AppUser.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Runs on every app start / browser refresh. Only a genuinely invalid
  /// session sends the user back to the login page; a slow or unreachable
  /// server keeps them signed in with the details remembered from last time.
  @override
  Future<AppUser?> restore() async {
    final session = _auth.currentSession;
    if (session == null) return null;
    try {
      if (session.isExpired) await _auth.refreshSession();
    } on AuthRetryableFetchException {
      return _remembered(); // offline: stay signed in
    } on AuthException {
      return null; // refresh token revoked / expired
    }
    try {
      return await _remember(
          AppUser.fromJson(await _get('/me') as Map<String, dynamic>));
    } on BackendException catch (e) {
      if (e.status == 401 || e.status == 403) return null;
      return _remembered();
    } catch (_) {
      return _remembered();
    }
  }

  @override
  Future<void> signOut() async {
    try {
      (await SharedPreferences.getInstance()).remove(_kUser);
    } catch (_) {}
    await _auth.signOut();
  }

  @override
  Future<void> sendPasswordReset(String email) =>
      _auth.resetPasswordForEmail(email.trim());

  // ---- profile
  @override
  Future<AppUser> updateProfile(
      {required String name, required String email}) async {
    final u = AppUser.fromJson(await _send('PATCH', '/me',
        body: {'name': name, 'email': email}) as Map<String, dynamic>);
    // The email lives in the JWT too, so pick up a fresh token.
    await _auth.refreshSession();
    return u;
  }

  @override
  Future<void> changePassword(
          {required String current, required String newPassword}) =>
      _post('/me/password',
          {'current_password': current, 'new_password': newPassword});

  // ---- distributor
  @override
  Future<List<Waiter>> waiters({bool all = false}) async =>
      ((await _get('/waiters', all ? {'all': '1'} : null)) as List)
          .map((e) => Waiter.fromJson(e as Map<String, dynamic>))
          .toList();

  @override
  Future<Waiter> registerWaiter(String name) async => Waiter.fromJson(
      await _post('/waiters', {'name': name}) as Map<String, dynamic>);

  @override
  Future<Waiter> updateWaiter(String waiterId,
          {String? name, bool? active}) async =>
      Waiter.fromJson(await _send('PATCH', '/waiters/$waiterId', body: {
        'name': ?name,
        'active': ?active,
      }) as Map<String, dynamic>);

  List<Pot> _pots(dynamic j) =>
      (j as List).map((e) => Pot.fromJson(e as Map<String, dynamic>)).toList();

  @override
  Future<List<Pot>> availablePots() async =>
      _pots(await _get('/pots/available'));

  @override
  Future<List<Pot>> allPots() async => _pots(await _get('/pots'));

  @override
  Future<List<Pot>> registerPots(int count) async =>
      _pots(await _post('/pots/register', {'count': count}));

  @override
  Future<void> setPotActive(String potId, bool active) =>
      _send('PATCH', '/pots/$potId', body: {'active': active});

  @override
  Future<PotToken> issueToken(
          {required String waiterId,
          required String potId,
          required int minutes,
          required double amount,
          required PayMethod method,
          PayTiming timing = PayTiming.immediate}) async =>
      _token(await _post('/tokens', {
        'waiter_id': waiterId,
        'pot_id': potId,
        'minutes': minutes,
        'amount': amount,
        'method': method.wire,
        'pay_timing': timing.wire,
      }));

  @override
  Future<PotToken> settlePayment(String tokenId, PayMethod method) async =>
      _token(await _post('/tokens/$tokenId/pay', {'method': method.wire}));

  @override
  Future<List<PotToken>> unpaidTokens() async =>
      _tokens(await _get('/tokens/unpaid'));

  @override
  Future<PotToken> extendToken(
          {required String tokenId,
          required int minutes,
          required double fee,
          required PayMethod method}) async =>
      _token(await _post('/tokens/$tokenId/extend',
          {'minutes': minutes, 'fee': fee, 'method': method.wire}));

  @override
  Future<PotToken> returnPot(String tokenId) async =>
      _token(await _post('/tokens/$tokenId/return'));

  @override
  Future<List<PotToken>> activeTokens() async =>
      _tokens(await _get('/tokens/active'));

  // ---- manager
  String _d(DateTime d) => d.toIso8601String();

  @override
  Future<DaySummary> daySummary(DateTime day) async {
    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1));
    final r = await Future.wait([
      tokensBetween(from, to),
      auditBetween(from, to),
    ]);
    return DaySummary(
        day: from,
        tokens: r[0] as List<PotToken>,
        audit: r[1] as List<AuditEntry>);
  }

  @override
  Future<List<PotToken>> tokensBetween(DateTime from, DateTime to) async =>
      _tokens(await _get(
          '/manager/tokens', {'from': _d(from.toUtc()), 'to': _d(to.toUtc())}));

  @override
  Future<List<AuditEntry>> auditBetween(DateTime from, DateTime to) async =>
      ((await _get('/manager/audit',
              {'from': _d(from.toUtc()), 'to': _d(to.toUtc())})) as List)
          .map((e) => AuditEntry.fromJson(e as Map<String, dynamic>))
          .toList();

  @override
  Future<List<AppUser>> users() async => ((await _get('/users')) as List)
      .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
      .toList();

  @override
  Future<EnrollResult> enrollUser(
      {required String name,
      required String email,
      required Role role}) async {
    final j = await _post('/manager/users',
        {'name': name, 'email': email, 'role': role.name}) as Map<String, dynamic>;
    return EnrollResult(AppUser.fromJson(j),
        tempPassword: j['temp_password'] as String?);
  }

  @override
  Future<void> deleteUser(String userId) => _send('DELETE', '/manager/users/$userId');

  @override
  Future<void> setUserActive(String userId, bool active) =>
      _send('PATCH', '/manager/users/$userId', body: {'active': active});

  @override
  Future<AppUser> editUser(String userId,
          {required String name, required String email}) async =>
      AppUser.fromJson(await _send('PATCH', '/manager/users/$userId',
          body: {'name': name, 'email': email}) as Map<String, dynamic>);

  @override
  Future<String?> resendCredentials(String userId) async {
    final j = await _post('/manager/users/$userId/resend') as Map<String, dynamic>;
    return j['temp_password'] as String?;
  }

  @override
  Future<List<SecurityAlert>> alerts() async =>
      ((await _get('/manager/alerts')) as List)
          .map((e) => SecurityAlert.fromJson(e as Map<String, dynamic>))
          .toList();

  @override
  Future<void> dismissAlert(String alertId) =>
      _post('/manager/alerts/$alertId/dismiss');

  @override
  Future<SmtpConfig> getSmtp() async =>
      SmtpConfig.fromJson(await _get('/manager/smtp') as Map<String, dynamic>);

  @override
  Future<void> saveSmtp(SmtpConfig cfg) =>
      _send('PUT', '/manager/smtp', body: cfg.toJson());

  @override
  Future<void> testSmtp(String toEmail) =>
      _post('/manager/smtp/test', {'to': toEmail});
}
