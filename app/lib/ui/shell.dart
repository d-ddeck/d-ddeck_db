import 'common/section_main_reporter.dart';
import 'update_dialog.dart';
import 'package:flutter/services.dart';
import '../state/theme_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'common/theme_mode_button.dart';
import 'auth/profile_page.dart';
import 'auth/sessions_page.dart';
import '../core/api_client.dart';
import '../core/config.dart';
import '../services/vpn_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user.dart';
import '../state/auth_state.dart';
import 'admin/admin_page.dart';
import 'alarm_settings_page.dart';
import 'alarm_list_page.dart';
import '../services/alarm_service.dart';
import 'auth/signup_page.dart';
import 'board/board_page.dart';
import 'calendar/calendar_page.dart';
import 'dashboard_page.dart';
import 'equipment/equipment_page.dart';
import 'notifications_page.dart';
import 'service/service_page.dart';
import 'worklog/worklog_page.dart';
import 'theme.dart';
import 'common/common.dart';
import 'vpn/vpn_setup_page.dart';

/// Root frame once signed in.
///
/// Uses a NavigationRail above [AppTheme.wideBreakpoint] and a bottom bar
/// below it, so the same build runs on a Windows window and an Android phone.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.equipmentTab});
  final EquipmentTab? equipmentTab;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.equipmentTab == null ? 0 : 2;
  final _equipmentKey = GlobalKey<EquipmentPageState>();
  final _visited = <int>{};
  final _sectionRevisions = List<int>.filled(7, 0);
  late final _sectionIsMain = List<bool>.filled(7, true)
    ..[2] =
        widget.equipmentTab == null ||
        widget.equipmentTab == EquipmentTab.overview;
  bool _railExpanded = true;
  bool _railTouched = false;
  Future<void> _railSave = Future.value();

  @override
  void initState() {
    super.initState();
    _loadRail();
  }

  Future<void> _loadRail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted && !_railTouched) {
        setState(
          () =>
              _railExpanded = prefs.getBool('appearance.rail_expanded') ?? true,
        );
      }
    } catch (_) {
      /* Keep the readable default if storage is unavailable. */
    }
  }

  void _toggleRail() {
    _railTouched = true;
    setState(() => _railExpanded = !_railExpanded);
    final expanded = _railExpanded;
    _railSave = _railSave
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setBool('appearance.rail_expanded', expanded)) {
            throw StateError('메뉴 설정 저장 실패');
          }
        })
        .catchError((Object _) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('메뉴 설정을 저장하지 못했습니다.')));
          }
        });
  }

  final _pagesKey = GlobalKey();

  void _backToSectionMain() {
    final destinations = _destinationsFor(context.read<AuthState>().role);
    final index = _index.clamp(0, destinations.length - 1);
    if (index == 2) {
      _equipmentKey.currentState?.backToMain();
      return;
    }
    // Detail/form routes already pop normally, including unsaved-form guards.
    // At the section root, return its tabs and transient view state to home.
    setState(() => _sectionRevisions[index]++);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final destinations = _destinationsFor(auth.role);

    // The admin tab disappears for non-admins, so clamp a stale index.
    final index = _index.clamp(0, destinations.length - 1);
    _visited.add(index);
    final wide = AppTheme.isWide(context);

    final body = EquipmentNavigation(
      open: (tab, filters) {
        setState(() => _index = 2);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _equipmentKey.currentState?.show(tab, filters);
        });
      },
      child: IndexedStack(
        key: _pagesKey,
        index: index,
        children: [
          for (var i = 0; i < destinations.length; i++)
            !_visited.contains(i)
                ? const SizedBox.shrink()
                : NotificationListener<SectionMainNotification>(
                    onNotification: (notification) {
                      if (_sectionIsMain[i] != notification.isMain) {
                        setState(() => _sectionIsMain[i] = notification.isMain);
                      }
                      return true;
                    },
                    child: destinations[i].label == '장비·매장'
                        ? EquipmentPage(
                            key: _equipmentKey,
                            tab: widget.equipmentTab ?? EquipmentTab.overview,
                          )
                        : KeyedSubtree(
                            key: ValueKey('section-$i-${_sectionRevisions[i]}'),
                            child: destinations[i].page,
                          ),
                  ),
        ],
      ),
    );

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToSectionMain();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _backToSectionMain,
          for (var i = 0; i < destinations.length && i < 7; i++)
            SingleActivator(
              [
                LogicalKeyboardKey.digit1,
                LogicalKeyboardKey.digit2,
                LogicalKeyboardKey.digit3,
                LogicalKeyboardKey.digit4,
                LogicalKeyboardKey.digit5,
                LogicalKeyboardKey.digit6,
                LogicalKeyboardKey.digit7,
              ][i],
              alt: true,
            ): () =>
                setState(() => _index = i),
        },
        child: FocusTraversalGroup(
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: _sectionIsMain[index]
                  ? Text(destinations[index].label)
                  : null,
              leading: _sectionIsMain[index]
                  ? null
                  : BackButton(onPressed: _backToSectionMain),
              actions: [
                if (auth.isLoggingOut)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ValueListenableBuilder<bool>(
                  valueListenable: context.read<ApiClient>().connected,
                  builder: (context, connected, _) => connected
                      ? const SizedBox.shrink()
                      : const Tooltip(
                          message: '서버 연결 끊김 · 다시 시도해 주세요',
                          child: Icon(Icons.cloud_off),
                        ),
                ),
                if (AlarmService.isSupported)
                  IconButton(
                    tooltip: '이 폰에 저장된 알람 보기',
                    icon: const Icon(Icons.alarm),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SyncedAlarmsPage(),
                      ),
                    ),
                  ),
                if (wide)
                  PopupMenuButton<bool>(
                    tooltip: '목록 밀도',
                    icon: const Icon(Icons.density_medium),
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(
                        value: false,
                        checked: !context.read<ThemeState>().compact,
                        child: const Text('기본 간격'),
                      ),
                      CheckedPopupMenuItem(
                        value: true,
                        checked: context.read<ThemeState>().compact,
                        child: const Text('촘촘히 보기'),
                      ),
                    ],
                    onSelected: (value) async {
                      try {
                        await context.read<ThemeState>().setCompact(value);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('목록 밀도를 저장하지 못했습니다.')),
                          );
                        }
                      }
                    },
                  ),
                const ThemeModeButton(),
                _NotificationButton(unread: auth.unreadCount),
                _AccountMenu(user: auth.user),
                const SizedBox(width: 8),
              ],
            ),
            body: wide
                ? Row(
                    children: [
                      SizedBox(
                        width: _railExpanded ? 220 : 88,
                        child: Column(
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: IconButton(
                                tooltip: _railExpanded ? '메뉴 접기' : '메뉴 펼치기',
                                onPressed: _toggleRail,
                                icon: _railExpanded
                                    ? const Icon(Icons.menu_open)
                                    : const Icon(Icons.menu),
                              ),
                            ),
                            Expanded(
                              child: NavigationRail(
                                extended: _railExpanded,
                                scrollable: true,
                                minExtendedWidth: 220,
                                selectedIndex: index,
                                onDestinationSelected: (i) =>
                                    setState(() => _index = i),
                                labelType: NavigationRailLabelType.none,
                                destinations: [
                                  for (final d in destinations)
                                    NavigationRailDestination(
                                      icon: Tooltip(
                                        message: d.label,
                                        child: Icon(d.icon),
                                      ),
                                      selectedIcon: Tooltip(
                                        message: d.label,
                                        child: Icon(d.selectedIcon),
                                      ),
                                      label: Text(d.label),
                                    ),
                                ],
                              ),
                            ),
                            const Divider(),
                            Padding(
                              padding: const EdgeInsets.all(AppSpace.sm),
                              child: Column(
                                children: [
                                  Text(
                                    auth.user?.fullName ?? '-',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    auth.role.label,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                  IconButton(
                                    tooltip: '로그아웃',
                                    onPressed: () => _logout(context),
                                    icon: const Icon(Icons.logout),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: body),
                    ],
                  )
                : body,
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: index < 4 ? index : 4,
                    onDestinationSelected: (i) {
                      if (i == 4) {
                        _showMore(destinations);
                      } else {
                        setState(() => _index = i);
                      }
                    },
                    destinations: [
                      for (final d in destinations.take(4))
                        NavigationDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selectedIcon),
                          label: d.label,
                        ),
                      const NavigationDestination(
                        icon: Icon(Icons.more_horiz),
                        label: '더보기',
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMore(List<_Destination> destinations) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 4; i < destinations.length; i++)
                ListTile(
                  leading: Icon(destinations[i].icon),
                  title: Text(destinations[i].label),
                  selected: _index == i,
                  onTap: () => Navigator.pop(context, i),
                ),
              ListTile(
                leading: const Icon(Icons.alarm),
                title: const Text('알람'),
                onTap: () => Navigator.pop(context, -1),
              ),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('내 정보'),
                onTap: () => Navigator.pop(context, -2),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected < 0) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => selected == -1
              ? const SyncedAlarmsPage()
              : Scaffold(
                  appBar: AppBar(title: const Text('내 정보')),
                  body: ListTile(
                    title: Text(context.read<AuthState>().user?.display ?? '-'),
                    subtitle: Text(context.read<AuthState>().user?.email ?? ''),
                    trailing: _AccountMenu(
                      user: context.read<AuthState>().user,
                    ),
                  ),
                ),
        ),
      );
    } else {
      setState(() => _index = selected);
    }
  }

  List<_Destination> _destinationsFor(Role role) => [
    const _Destination(
      label: '홈',
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
      page: DashboardPage(),
    ),
    const _Destination(
      label: '대응',
      icon: Icons.build_outlined,
      selectedIcon: Icons.build,
      page: ServicePage(),
    ),
    const _Destination(
      label: '장비·매장',
      icon: Icons.inventory_2_outlined,
      selectedIcon: Icons.inventory_2,
      page: EquipmentPage(),
    ),
    const _Destination(
      label: '근무일지',
      icon: Icons.assignment_outlined,
      selectedIcon: Icons.assignment,
      page: WorkLogPage(),
    ),
    const _Destination(
      label: '캘린더',
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month,
      page: CalendarPage(),
    ),
    const _Destination(
      label: '게시판',
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
      page: BoardPage(),
    ),
    if (role.atLeast(Role.admin))
      const _Destination(
        label: '관리',
        icon: Icons.admin_panel_settings_outlined,
        selectedIcon: Icons.admin_panel_settings,
        page: AdminPage(),
      ),
  ];
}

class _Destination {
  const _Destination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.page,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget page;
}

class _NotificationButton extends StatelessWidget {
  const _NotificationButton({required this.unread});
  final int unread;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '알림',
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const NotificationsPage())),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.user});
  final UserProfile? user;

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthState>();
    return PopupMenuButton<String>(
      tooltip: '설정',
      icon: const Icon(Icons.settings_outlined),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                user?.display ?? '-',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                user?.email ?? '',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              StatusChip(
                label: user?.role.label ?? '-',
                color: Theme.of(context).colorScheme.primary,
                dense: true,
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (AlarmService.isSupported)
          const PopupMenuItem(value: 'alarms', child: Text('일정 알림')),
        const PopupMenuItem(value: 'profile', child: Text('내 정보 수정')),
        const PopupMenuItem(value: 'sessions', child: Text('로그인 기기·세션')),
        const PopupMenuItem(value: 'password', child: Text('비밀번호 변경')),
        const PopupMenuItem(value: 'server', child: Text('서버 정보')),
        const PopupMenuItem(value: 'update', child: Text('업데이트 확인')),
        if (VpnService.isSupported)
          const PopupMenuItem(value: 'vpn', child: Text('사외 접속(VPN) 설정')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('로그아웃')),
      ],
      onSelected: (value) async {
        switch (value) {
          case 'profile':
            Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const ProfilePage()),
            );
          case 'sessions':
            Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SessionsPage()),
            );
          case 'vpn':
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const VpnSetupPage()));
          case 'alarms':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AlarmSettingsPage()),
            );
          case 'password':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
            );
          case 'update':
            await checkClientUpdate(
              context,
              context.read<AuthState>().serverUrl,
            );
            break;
          case 'server':
            final controller = TextEditingController(text: auth.serverUrl);
            final next = await showDialog<String>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('서버 주소 변경'),
                content: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: '서버 주소',
                    helperText: '변경 후 새 서버에 다시 로그인합니다.',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () {
                      final normalized = AppConfig.normalizeServerUrl(
                        controller.text.trim(),
                      );
                      final uri = Uri.tryParse(normalized);
                      if (uri == null ||
                          !['http', 'https'].contains(uri.scheme) ||
                          uri.host.isEmpty) {
                        return;
                      }
                      Navigator.pop(dialogContext, normalized);
                    },
                    child: const Text('변경'),
                  ),
                ],
              ),
            );
            Future<void>.delayed(
              const Duration(milliseconds: 350),
              controller.dispose,
            );
            if (next != null && next != auth.serverUrl) {
              await auth.logout();
              await auth.setServerUrl(next);
            }
          case 'logout':
            await _logout(context);
        }
      },
    );
  }
}

Future<void> _logout(BuildContext context) async {
  final auth = context.read<AuthState>();
  if (await ConfirmDialog.show(
    context,
    title: '로그아웃',
    message: '로그아웃하시겠습니까?',
    confirmLabel: '로그아웃',
  )) {
    await auth.logout();
  }
}
