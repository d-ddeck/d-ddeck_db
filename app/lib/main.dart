import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/config.dart';
import 'core/token_store.dart';
import 'data/admin_repository.dart';
import 'data/auth_repository.dart';
import 'data/board_repository.dart';
import 'data/calendar_repository.dart';
import 'data/inventory_repository.dart';
import 'data/service_repository.dart';
import 'state/auth_state.dart';
import 'ui/auth/login_page.dart';
import 'ui/auth/signup_page.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read the site default the installer wrote next to the executable, before
  // anything asks AppConfig for a server address.
  await AppConfig.loadSiteConfig();

  // Composition root. Everything is plain constructor injection so a screen's
  // dependencies are visible in one place rather than behind a service locator.
  final tokenStore = TokenStore();
  final api = ApiClient(tokenStore: tokenStore);

  final authRepo = AuthRepository(api);
  final calendarRepo = CalendarRepository(api);

  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<AuthRepository>.value(value: authRepo),
        Provider<ServiceRepository>(create: (_) => ServiceRepository(api)),
        Provider<InventoryRepository>(create: (_) => InventoryRepository(api)),
        Provider<BoardRepository>(create: (_) => BoardRepository(api)),
        Provider<CalendarRepository>.value(value: calendarRepo),
        Provider<AdminRepository>(create: (_) => AdminRepository(api)),
        ChangeNotifierProvider<AuthState>(
          create: (_) => AuthState(
            api: api,
            tokenStore: tokenStore,
            authRepo: authRepo,
            calendarRepo: calendarRepo,
          )..bootstrap(),
        ),
      ],
      child: const DdeckApp(),
    ),
  );
}

class DdeckApp extends StatelessWidget {
  const DdeckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _RootRouter(),
    );
  }
}

/// Switches on the auth phase. Keeping routing here means a session that dies
/// mid-request lands on the login page from anywhere in the app.
class _RootRouter extends StatelessWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context) {
    final phase = context.select<AuthState, AuthPhase>((s) => s.phase);
    return switch (phase) {
      AuthPhase.loading => const AuthLoadingPage(),
      AuthPhase.loggedOut => const LoginPage(),
      AuthPhase.mustChangePassword => const ChangePasswordPage(forced: true),
      AuthPhase.ready => const HomeShell(),
    };
  }
}
