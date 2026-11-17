import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'models.dart';

/// System notifications for "time is up".
///
/// * Android / iOS: each pot's due time is scheduled with the OS, so the alert
///   arrives even when the app is closed or the phone is locked.
/// * Web / macOS: shown when the app notices the time is up (the app must be open).
/// * Windows / Linux: no system notification; the in-app alert is used.
class TimeUpNotifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  final Map<int, DateTime> _scheduled = {};

  static bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static bool get supported =>
      kIsWeb || _mobile || defaultTargetPlatform == TargetPlatform.macOS;

  /// True when the OS fires the alert at the due time by itself.
  static bool get schedulesInBackground => _mobile;

  static const _channel = AndroidNotificationDetails(
    'time_up',
    'Time is up',
    channelDescription: 'Tells you when a pot’s time has run out',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
  );
  static const _details = NotificationDetails(
    android: _channel,
    iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    macOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    web: WebNotificationDetails(requireInteraction: true),
  );

  Future<void> init() async {
    if (_ready || !supported) return;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestSoundPermission: false,
              requestBadgePermission: false),
          macOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestSoundPermission: false,
              requestBadgePermission: false),
          web: WebInitializationSettings(),
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  /// Asks the user to allow notifications. On the web this must be called from
  /// a button press. Returns whether alerts are allowed.
  Future<bool> requestPermission() async {
    await init();
    if (!_ready) return false;
    try {
      if (kIsWeb) {
        final web = _plugin.resolvePlatformSpecificImplementation<
            WebFlutterLocalNotificationsPlugin>();
        if (web == null) return false;
        if (web.permissionStatus != WebNotificationPermission.granted) {
          await web.requestNotificationsPermission();
        }
        return web.permissionStatus == WebNotificationPermission.granted;
      }
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
          final ok = await a?.requestNotificationsPermission() ?? false;
          // Needed for alerts to fire exactly on time; not fatal if refused.
          try {
            await a?.requestExactAlarmsPermission();
          } catch (_) {}
          return ok;
        case TargetPlatform.iOS:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                      IOSFlutterLocalNotificationsPlugin>()
                  ?.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
        case TargetPlatform.macOS:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                      MacOSFlutterLocalNotificationsPlugin>()
                  ?.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
        default:
          return false;
      }
    } catch (e) {
      debugPrint('Notification permission failed: $e');
      return false;
    }
  }

  static int idFor(PotToken t) => t.id.hashCode & 0x7fffffff;

  /// Keeps the OS-scheduled alerts in step with the pots that are out
  /// (new pot -> schedule, extended -> reschedule, returned -> cancel).
  Future<void> sync(List<PotToken> active) async {
    if (!_ready || !_mobile) return;
    final now = DateTime.now();
    final wanted = <int, PotToken>{
      for (final t in active)
        if (t.dueAt != null && t.dueAt!.isAfter(now)) idFor(t): t,
    };
    for (final id in _scheduled.keys.toList()) {
      if (!wanted.containsKey(id)) {
        await _safe(() => _plugin.cancel(id: id));
        _scheduled.remove(id);
      }
    }
    for (final e in wanted.entries) {
      final due = e.value.dueAt!;
      if (_scheduled[e.key] == due) continue;
      await _schedule(e.key, e.value, due);
      _scheduled[e.key] = due;
    }
  }

  Future<void> _schedule(int id, PotToken t, DateTime due) async {
    final when = tz.TZDateTime.from(due, tz.UTC); // absolute instant
    Future<void> go(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id: id,
          title: 'Time is up: ${t.potLabel ?? 'pot'}',
          body: '${t.waiterName} – tell them to bring the pot back.',
          scheduledDate: when,
          notificationDetails: _details,
          androidScheduleMode: mode,
        );
    try {
      await go(AndroidScheduleMode.exactAllowWhileIdle);
    } catch (_) {
      // exact alarms not permitted: fall back to "about on time"
      await _safe(() => go(AndroidScheduleMode.inexactAllowWhileIdle));
    }
  }

  /// Immediate alert (web / macOS, where nothing is scheduled with the OS).
  Future<void> showNow(PotToken t) async {
    if (!_ready || _mobile) return;
    await _safe(() => _plugin.show(
          id: idFor(t),
          title: 'Time is up: ${t.potLabel ?? 'pot'}',
          body: '${t.waiterName} – tell them to bring the pot back.',
          notificationDetails: _details,
        ));
  }

  Future<void> cancelAll() async {
    _scheduled.clear();
    if (_ready) await _safe(_plugin.cancelAll);
  }

  Future<void> _safe(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('Notification call failed: $e');
    }
  }
}
