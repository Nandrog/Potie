import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/backend.dart';
import 'models.dart';
import 'notifier.dart';

/// Keeps the list of pots that are out up to date and raises an event the
/// moment one runs out of time. Used by the distributor and the manager.
class LiveTokens extends ChangeNotifier {
  LiveTokens(this.backend, {this.notifier});
  final Backend backend;
  final TimeUpNotifier? notifier;

  List<PotToken> tokens = const [];
  DateTime? updatedAt;
  bool loaded = false;
  String? error;

  /// Fires once per pot when its time runs out.
  final _due = StreamController<PotToken>.broadcast();
  Stream<PotToken> get dueEvents => _due.stream;

  final Set<String> _alerted = {};
  bool _first = true;
  Timer? _poll, _tick;
  bool _running = false;

  /// Start for roles that watch the floor; stop when signed out.
  void bind(AppUser? user) {
    final watch = user != null &&
        (user.role == Role.distributor || user.role == Role.manager);
    if (watch && !_running) {
      _running = true;
      notifier?.init();
      if (TimeUpNotifier.schedulesInBackground) notifier?.requestPermission();
      refresh();
      _poll = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => checkDue(DateTime.now()));
    } else if (!watch && _running) {
      _stop();
    }
  }

  void _stop() {
    _running = false;
    _poll?.cancel();
    _tick?.cancel();
    tokens = const [];
    loaded = false;
    _alerted.clear();
    _first = true;
    notifier?.cancelAll();
    notifyListeners();
  }

  Future<void> refresh() async {
    try {
      final l = [...await backend.activeTokens()]
        ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
      tokens = l;
      error = null;
      updatedAt = DateTime.now();
      loaded = true;
      // Pots already overdue when the app opens are visible on the board; only
      // pots that run out while watching raise an alert.
      if (_first) {
        _first = false;
        _alerted.addAll(l.where((t) => t.overdue).map((t) => t.id));
      }
      // An extension makes a pot "not overdue" again, so it can alert again later.
      _alerted.removeWhere((id) => !l.any((t) => t.id == id && t.overdue));
      notifier?.sync(l);
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  /// Raises the event for every pot whose time has run out and wasn't alerted yet.
  @visibleForTesting
  void checkDue(DateTime now) {
    for (final t in tokens) {
      final due = t.dueAt;
      if (due == null || t.status != TokenStatus.out) continue;
      if (!due.isAfter(now) && _alerted.add(t.id)) {
        notifier?.showNow(t);
        _due.add(t);
      }
    }
  }

  @visibleForTesting
  void setTokensForTest(List<PotToken> l) => tokens = l;

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _due.close();
    super.dispose();
  }
}
