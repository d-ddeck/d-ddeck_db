import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/admin_repository.dart';
import '../../core/version.dart';
import '../../data/auth_repository.dart';
import '../../models/admin.dart';
import '../../models/common.dart';
import '../../models/user.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';
import 'accounts_tab.dart';
import 'departments_page.dart';
import 'settings_page.dart';

part 'approval_tab.dart';
part 'settings_hub_tab.dart';
part 'audit_tab.dart';
part 'health_tab.dart';

/// 관리기능: accounts, approval queue, settings, audit log and server status.
class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthState>().isAdmin;
    return PageBody(
      child: DefaultTabController(
        key: ValueKey(isAdmin),
        length: isAdmin ? 5 : 4,
        child: Column(
          children: [
            if (isAdmin)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DepartmentsPage()),
                  ),
                  icon: const Icon(Icons.account_tree_outlined),
                  label: const Text("부서 관리"),
                ),
              ),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                const Tab(
                  text: '가입 승인',
                  icon: Icon(Icons.how_to_reg, size: 18),
                ),
                if (isAdmin)
                  const Tab(
                    text: '계정 관리',
                    icon: Icon(Icons.people_outline, size: 18),
                  ),
                const Tab(text: '기능 설정', icon: Icon(Icons.tune, size: 18)),
                const Tab(
                  text: '감사 로그',
                  icon: Icon(Icons.receipt_long, size: 18),
                ),
                const Tab(
                  text: '서버 상태',
                  icon: Icon(Icons.monitor_heart, size: 18),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  const _ApprovalTab(),
                  if (isAdmin) const AccountsTab(),
                  const _SettingsHubTab(),
                  const _AuditTab(),
                  const _HealthTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageButtons extends StatelessWidget {
  const _PageButtons({
    required this.page,
    required this.hasMore,
    required this.onChanged,
  });
  final int page;
  final bool hasMore;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: '이전 페이지',
        onPressed: page > 1 ? () => onChanged(page - 1) : null,
        icon: const Icon(Icons.chevron_left),
      ),
      Text('$page 페이지'),
      IconButton(
        tooltip: '다음 페이지',
        onPressed: hasMore ? () => onChanged(page + 1) : null,
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
}
