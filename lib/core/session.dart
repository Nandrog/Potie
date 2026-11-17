import 'package:flutter/foundation.dart';

import '../data/backend.dart';
import 'models.dart';

class Session extends ChangeNotifier {
  Session(this.backend);
  final Backend backend;

  AppUser? user;
  bool restoring = true;

  Future<void> restore() async {
    try {
      user = await backend.restore();
    } catch (_) {
      user = null;
    } finally {
      restoring = false;
      notifyListeners();
    }
  }

  Future<void> signIn(String email, String password) async {
    user = await backend.signIn(email, password);
    notifyListeners();
  }

  Future<void> updateProfile({required String name, required String email}) async {
    user = await backend.updateProfile(name: name, email: email);
    notifyListeners();
  }

  Future<void> signOut() async {
    await backend.signOut();
    user = null;
    notifyListeners();
  }
}
