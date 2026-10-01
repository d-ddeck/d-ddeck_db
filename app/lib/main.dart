import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/config.dart';
import 'core/company_tls.dart';
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
import 'services/alarm_widget_service.dart';
import 'ui/alarm_widget_page.dart';
import 'services/vpn_service.dart';
import 'state/auth_state.dart';
import 'state/theme_state.dart';
import 'ui/alarm_ring_page.dart';
import 'ui/auth/login_page.dart';
import 'ui/auth/signup_page.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/update_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read the site default the installer wrote next to the executable, before
  // anything asks AppConfig for a server address.
  await CompanyTls.initialize();
  await AppConfig.loadSiteConfig();
  final themeState = ThemeState();
  await themeState.load();

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
  await AlarmWidgetService.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeState>.value(value: themeState),
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

class DdeckApp extends StatefulWidget {
  const DdeckApp({super.key});
  @override
  State<DdeckApp> createState() => _DdeckAppState();
}

class _DdeckAppState extends State<DdeckApp> {
  final _navigator = GlobalKey<NavigatorState>();
  AuthPhase? _previous;
  String? _updateServer;

  @override
  void initState() {
    super.initState();
    AlarmWidgetService.launch.addListener(_openWidget);
  }

  @override
  void dispose() {
    AlarmWidgetService.launch.removeListener(_openWidget);
    super.dispose();
  }

  void _openWidget() {
    if (AlarmWidgetService.launch.value == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || context.read<AuthState>().phase == AuthPhase.loading) {
        return;
      }
      final id = AlarmWidgetService.launch.value;
      final navigator = _navigator.currentState;
      if (id == null || navigator == null) return;
      AlarmWidgetService.launch.value = null;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => AlarmWidgetPage(reminderId: id),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final phase = context.select<AuthState, AuthPhase>((s) => s.phase);
    if (_previous != phase &&
        (phase == AuthPhase.loggedOut ||
            phase == AuthPhase.mustChangePassword)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _navigator.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
    _previous = phase;
    if (AlarmWidgetService.launch.value != null) _openWidget();
    final server = context.read<ApiClient>().serverUrl;
    if (phase != AuthPhase.loading && _updateServer != server) {
      _updateServer = server;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigatorContext = _navigator.currentState?.overlay?.context;
        if (mounted && navigatorContext != null) {
          checkClientUpdate(navigatorContext, server, silent: true);
        }
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) => MaterialApp(
        navigatorKey: _navigator,
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(
          compact:
              context.watch<ThemeState>().compact &&
              constraints.maxWidth >= 900,
        ),
        darkTheme: AppTheme.dark(
          compact:
              context.watch<ThemeState>().compact &&
              constraints.maxWidth >= 900,
        ),
        themeMode: context.watch<ThemeState>().mode,
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
