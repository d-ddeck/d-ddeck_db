import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user.dart';
import '../state/auth_state.dart';
import 'admin/admin_page.dart';
import 'auth/signup_page.dart';
import 'board/board_page.dart';
import 'calendar/calendar_page.dart';
import 'dashboard_page.dart';
import 'inventory/inventory_page.dart';
import 'notifications_page.dart';
import 'service/service_page.dart';
import 'theme.dart';

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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final destinations = _destinationsFor(auth.role);

    // The admin tab disappears for non-admins, so clamp a stale index.
    final index = _index.clamp(0, destinations.length - 1);
    final wide = AppTheme.isWide(context);

    final body = IndexedStack(
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
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final d in destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: d.label,
                  ),
              ],
            ),
    );
  }

  List<_Destination> _destinationsFor(Role role) => [
        const _Destination(
          label: '홈',
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          page: DashboardPage(),
        ),
        const _Destination(
          label: '서비스',
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
      tooltip: user?.fullName ?? '계정',
      icon: CircleAvatar(
        radius: 14,
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          user == null || user!.fullName.isEmpty
              ? '?'
              : user!.fullName.characters.first,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
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
        const PopupMenuItem(value: 'password', child: Text('비밀번호 변경')),
        const PopupMenuItem(value: 'server', child: Text('서버 정보')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('로그아웃')),
      ],
      onSelected: (value) async {
        switch (value) {
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
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('로그아웃'),
                content: const Text('로그아웃하시겠습니까?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('로그아웃'),
                  ),
                ],
              ),
            );
            if (ok == true) await auth.logout();
        }
      },
    );
  }
}
