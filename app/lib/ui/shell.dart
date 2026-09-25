import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user.dart';
import '../state/auth_state.dart';
import 'admin/admin_page.dart';
import 'alarm_settings_page.dart';
import 'auth/signup_page.dart';
import 'board/board_page.dart';
import 'calendar/calendar_page.dart';
import 'dashboard_page.dart';
import 'inventory/inventory_page.dart';
import 'notifications_page.dart';
import 'service/service_page.dart';
import 'store/store_page.dart';
import 'theme.dart';
import 'common/common.dart';
import 'vpn/vpn_setup_page.dart';

/// Root frame once signed in.
///
/// Uses a NavigationRail above [AppTheme.wideBreakpoint] and a bottom bar
/// below it, so the same build runs on a Windows window and an Android phone.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _railExpanded = false;
  final _pagesKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final destinations = _destinationsFor(auth.role);

    // The admin tab disappears for non-admins, so clamp a stale index.
    final index = _index.clamp(0, destinations.length - 1);
    final wide = AppTheme.isWide(context);

    final body = IndexedStack(
      key: _pagesKey,
      index: index,
      children: destinations.map((d) => d.page).toList(),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(destinations[index].label),
        actions: [
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
                  child: Column(children: [
                    Align(alignment: Alignment.centerRight, child: IconButton(
                      tooltip: _railExpanded ? '메뉴 접기' : '메뉴 펼치기',
                      onPressed: () => setState(() => _railExpanded = !_railExpanded),
                      icon: Icon(_railExpanded ? Icons.menu_open : Icons.menu),
                    )),
                    Expanded(child: NavigationRail(
                      extended: _railExpanded,
                      scrollable: true,
                      minExtendedWidth: 220,
                      selectedIndex: index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: NavigationRailLabelType.none,
                      destinations: [for (final d in destinations) NavigationRailDestination(
                        icon: Tooltip(message: d.label, child: Icon(d.icon)),
                        selectedIcon: Tooltip(message: d.label, child: Icon(d.selectedIcon)),
                        label: Text(d.label),
                      )],
                    )),
                    const Divider(),
                    Padding(padding: const EdgeInsets.all(AppSpace.sm), child: Column(children: [
                      Text(auth.user?.fullName ?? '-', maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(auth.role.label, style: Theme.of(context).textTheme.labelSmall),
                      IconButton(tooltip: '로그아웃', onPressed: () => _logout(context),
                        icon: const Icon(Icons.logout)),
                    ])),
                  ]),
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
                const NavigationDestination(icon: Icon(Icons.more_horiz), label: '더보기'),
              ],
            ),
    );
  }

  Future<void> _showMore(List<_Destination> destinations) async {
    final selected = await showModalBottomSheet<int>(context: context,
      showDragHandle: true, builder: (context) => SafeArea(child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 4; i < destinations.length; i++) ListTile(
            leading: Icon(destinations[i].icon), title: Text(destinations[i].label),
            selected: _index == i, onTap: () => Navigator.pop(context, i),
          ),
        ]),
      )));
    if (selected != null && mounted) setState(() => _index = selected);
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
          label: '재고',
          icon: Icons.inventory_2_outlined,
          selectedIcon: Icons.inventory_2,
          page: InventoryPage(),
        ),
        const _Destination(
          label: '매장',
          // storefront_outlined(0xf3ef) 대신 store(0xe60a). 코드포인트가 낮아
          // 글리프가 빠질 여지가 없다.
          icon: Icons.store_mall_directory_outlined,
          selectedIcon: Icons.store,
          page: StorePage(),
        ),
        const _Destination(
          label: '게시판',
          icon: Icons.forum_outlined,
          selectedIcon: Icons.forum,
          page: BoardPage(),
        ),
        const _Destination(
          label: '캘린더',
          icon: Icons.calendar_month_outlined,
          selectedIcon: Icons.calendar_month,
          page: CalendarPage(),
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
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NotificationsPage()),
      ),
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
                  color: Theme.of(context).colorScheme.outline,
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
        const PopupMenuItem(value: 'alarms', child: Text('일정 알림')),
        const PopupMenuItem(value: 'password', child: Text('비밀번호 변경')),
        const PopupMenuItem(value: 'server', child: Text('서버 정보')),
        const PopupMenuItem(value: 'vpn', child: Text('사외 접속(VPN) 설정')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('로그아웃')),
      ],
      onSelected: (value) async {
        switch (value) {
          case 'vpn':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const VpnSetupPage()),
            );
          case 'alarms':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AlarmSettingsPage()),
            );
          case 'password':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
            );
          case 'server':
            showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('서버 정보'),
                content: SelectableText(auth.serverUrl),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('닫기'),
                  ),
                ],
              ),
            );
          case 'logout':
            await _logout(context);
        }
      },
    );
  }
}

Future<void> _logout(BuildContext context) async {
  final auth = context.read<AuthState>();
  if (await ConfirmDialog.show(context, title: '로그아웃',
      message: '로그아웃하시겠습니까?', confirmLabel: '로그아웃')) {
    await auth.logout();
  }
}
