import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'core/live_tokens.dart';
import 'core/notifier.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'data/http_backend.dart';
import 'features/auth/login_page.dart';
import 'features/distributor/distributor_home.dart';
import 'features/manager/manager_home.dart';
import 'core/models.dart';

/// Set at build time (see app.env):
///   flutter build apk --dart-define-from-file=app.env
const apiUrl = String.fromEnvironment('API_URL');
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (apiUrl.isEmpty || supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
    return runApp(const _SetupError(
        'This build has no server settings.\nBuild it with --dart-define-from-file=app.env.'));
  }
  try {
    await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
  } catch (e) {
    return runApp(_SetupError('Could not start: $e'));
  }
  final backend = HttpBackend(apiUrl);
  final session = Session(backend)..restore();
  final theme = await ThemeController.load();
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: session),
      ChangeNotifierProvider.value(value: theme),
      // Polls the pots that are out and raises "time is up" alerts while a
      // distributor or manager is signed in.
      ChangeNotifierProxyProvider<Session, LiveTokens>(
        create: (_) => LiveTokens(backend, notifier: TimeUpNotifier()),
        update: (_, s, live) => live!..bind(s.user),
      ),
    ],
    child: const PotieApp(),
  ));
}

class PotieApp extends StatelessWidget {
  const PotieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Potie',
      debugShowCheckedModeBanner: false,
      theme: Brand.theme(Brightness.light),
      darkTheme: Brand.theme(Brightness.dark),
      themeMode: context.watch<ThemeController>().mode,
      home: const _Gate(),
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    if (s.restoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final u = s.user;
    if (u == null) return const LoginPage();
    return switch (u.role) {
      Role.manager => const ManagerHome(),
      Role.distributor => const DistributorHome(),
    };
  }
}

class _SetupError extends StatelessWidget {
  const _SetupError(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(message, textAlign: TextAlign.center))),
        ),
      );
}
