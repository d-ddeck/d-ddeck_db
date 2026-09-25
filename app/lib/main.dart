import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/config.dart';
import 'core/token_store.dart';
import 'data/admin_repository.dart';
import 'data/auth_repository.dart';
import 'data/board_repository.dart';
import 'data/calendar_repository.dart';
import 'data/file_repository.dart';
import 'data/inventory_repository.dart';
import 'data/service_repository.dart';
import 'data/store_repository.dart';
import 'data/worklog_repository.dart';
import 'services/alarm_service.dart';
import 'services/vpn_service.dart';
import 'state/auth_state.dart';
import 'ui/alarm_ring_page.dart';
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

  // 일정 알람은 기기가 직접 울린다. 서버·VPN 이 끊겨도 동작해야 하므로
  // 앱 시작 시 준비해 둔다.
  final alarms = AlarmService();
  await alarms.init();

  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<AuthRepository>.value(value: authRepo),
        Provider<ServiceRepository>(create: (_) => ServiceRepository(api)),
        Provider<InventoryRepository>(create: (_) => InventoryRepository(api)),
        Provider<BoardRepository>(create: (_) => BoardRepository(api)),
        Provider<CalendarRepository>.value(value: calendarRepo),
        Provider<StoreRepository>(create: (_) => StoreRepository(api)),
        Provider<WorkLogRepository>(create: (_) => WorkLogRepository(api)),
        Provider<FileRepository>(create: (_) => FileRepository(api)),
        ChangeNotifierProvider<VpnService>(
          create: (_) => VpnService()..bootstrap(),
        ),
        Provider<AdminRepository>(create: (_) => AdminRepository(api)),
        Provider<AlarmService>.value(value: alarms),
        ChangeNotifierProvider<AuthState>(
          create: (_) => AuthState(
            api: api,
            tokenStore: tokenStore,
            authRepo: authRepo,
            calendarRepo: calendarRepo,
            alarms: alarms,
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
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('ko', 'KR'), Locale('en')],
      home: const _RootRouter(),
      builder: (context, child) => ValueListenableBuilder(
        valueListenable: context.read<AlarmService>().active,
        builder: (context, alarm, _) => Stack(
          fit: StackFit.expand,
          children: [
            if (child != null) child,
            if (alarm != null)
              Navigator(
                key: ValueKey('ring-${alarm.id}'),
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => AlarmRingPage(alarm: alarm),
                ),
              ),
          ],
        ),
      ),
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
