import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../data/auth_repository.dart';
import '../../models/admin.dart';
import '../../models/common.dart';
import '../../models/user.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';
import 'settings_page.dart';

/// 관리기능: approval queue, settings, audit log and server status.
class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '가입 승인', icon: Icon(Icons.how_to_reg, size: 18)),
            Tab(text: '기능 설정', icon: Icon(Icons.tune, size: 18)),
            Tab(text: '감사 로그', icon: Icon(Icons.receipt_long, size: 18)),
            Tab(text: '서버 상태', icon: Icon(Icons.monitor_heart, size: 18)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: const [
              _ApprovalTab(),
              _SettingsHubTab(),
              _AuditTab(),
              _HealthTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class _ApprovalTab extends StatefulWidget {
  const _ApprovalTab();

  @override
  State<_ApprovalTab> createState() => _ApprovalTabState();
}

class _ApprovalTabState extends State<_ApprovalTab> {
  final _viewKey = GlobalKey<AsyncViewState<PagedList<UserProfile>>>();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AuthRepository>();
    return AsyncView<PagedList<UserProfile>>(
      key: _viewKey,
      load: () => repo.pendingUsers(size: 50),
      emptyCheck: (p) => p.isEmpty,
      emptyMessage: '승인 대기 중인 계정이 없습니다.',
      emptyIcon: Icons.how_to_reg,
      builder: (context, page, reload) => ListView.separated(
        itemCount: page.items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final u = page.items[i];
          return ListTile(
            isThreeLine: true,
            title: Text(
              '${u.fullName}${u.position != null ? ' ${u.position}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(u.email, style: const TextStyle(fontSize: 12)),
                Text(
                  '신청 ${Fmt.dateTime(u.createdAt)}'
                  '${u.phone != null ? ' · ${u.phone}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                if (u.signupNote?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '"${u.signupNote}"',
                      style: const TextStyle(
                          fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _reject(u, reload),
                  child: const Text('반려'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () => _approve(u, reload),
                  child: const Text('승인'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _approve(UserProfile user, VoidCallback reload) async {
    final auth = context.read<AuthState>();
    final repo = context.read<AuthRepository>();
    final departments = await repo.departments();
    if (!mounted) return;

    var role = Role.member;
    String? departmentId = user.departmentId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text('${user.fullName} 승인'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<Role>(
                initialValue: role,
                decoration: const InputDecoration(labelText: '부여할 권한'),
                isExpanded: true,
                items: [
                  for (final r in Role.values)
                    DropdownMenuItem(
                      value: r,
                      // Nobody may grant a role at or above their own level;
                      // disabling here matches the server's rule instead of
                      // letting the request fail.
                      enabled: auth.role == Role.superadmin ||
                          r.level < auth.role.level,
                      child: Text(
                        r.label,
                        style: TextStyle(
                          color: (auth.role == Role.superadmin ||
                                  r.level < auth.role.level)
                              ? null
                              : Theme.of(ctx).disabledColor,
                        ),
                      ),
                    ),
                ],
                onChanged: (v) => setInner(() => role = v ?? role),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: departmentId,
                decoration: const InputDecoration(labelText: '부서'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('미지정')),
                  for (final d in departments)
                    DropdownMenuItem(value: d.id, child: Text(d.name)),
                ],
                onChanged: (v) => setInner(() => departmentId = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('승인'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await runGuarded(
      context,
      () => repo.approve(user.id, role, departmentId: departmentId),
      successMessage: '${user.fullName}님을 승인했습니다.',
    );
    if (ok) reload();
  }

  Future<void> _reject(UserProfile user, VoidCallback reload) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${user.fullName} 반려'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '반려 사유 *',
            helperText: '신청자에게 그대로 전달됩니다.',
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('반려'),
          ),
        ],
      ),
    );
    if (confirmed != true || controller.text.trim().isEmpty || !mounted) return;

    final ok = await runGuarded(
      context,
      () => context
          .read<AuthRepository>()
          .reject(user.id, controller.text.trim()),
      successMessage: '반려 처리했습니다.',
    );
    if (ok) reload();
  }
}

/// Entry point to the six settings screens. One screen serves all of them.
class _SettingsHubTab extends StatelessWidget {
  const _SettingsHubTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '각 기능의 동작 방식과 분류 항목을 여기서 변경합니다. '
                    '저장 즉시 모든 사용자에게 적용됩니다.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final module in SettingsModule.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                leading: Icon(_iconFor(module)),
                title: Text(module.label),
                subtitle: Text(
                  _descriptionFor(module),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ModuleSettingsPage(module: module),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static IconData _iconFor(SettingsModule m) => switch (m) {
        SettingsModule.system => Icons.settings,
        SettingsModule.auth => Icons.verified_user_outlined,
        SettingsModule.service => Icons.build_outlined,
        SettingsModule.inventory => Icons.inventory_2_outlined,
        SettingsModule.board => Icons.forum_outlined,
        SettingsModule.calendar => Icons.calendar_month_outlined,
      };

  static String _descriptionFor(SettingsModule m) => switch (m) {
        SettingsModule.system => '회사명, 시간대, 점검 모드',
        SettingsModule.auth => '가입 승인 정책, 로그인 잠금, 기본 권한',
        SettingsModule.service => '접수번호 규칙, 처리 기한, 서비스/증상/원인/조치 분류',
        SettingsModule.inventory => '자산번호 규칙, 안전재고 경고, 자산 분류',
        SettingsModule.board => '첨부 용량, 기본 목록 개수',
        SettingsModule.calendar => '기본 알림 시점, 업무 시간, 일정 유형',
      };
}

class _AuditTab extends StatefulWidget {
  const _AuditTab();

  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  final _viewKey = GlobalKey<AsyncViewState<List<AuditLog>>>();
  String? _action;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AdminRepository>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('전체'),
                  selected: _action == null,
                  onSelected: (_) => setState(() {
                    _action = null;
                    _viewKey.currentState?.reload();
                  }),
                ),
                for (final entry in AuditLog.actionLabels.entries) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: _action == entry.key,
                    onSelected: (_) => setState(() {
                      _action = entry.key;
                      _viewKey.currentState?.reload();
                    }),
                  ),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: AsyncView<List<AuditLog>>(
            key: _viewKey,
            load: () => repo.auditLogs(action: _action, size: 100),
            emptyCheck: (l) => l.isEmpty,
            emptyMessage: '기록이 없습니다.',
            emptyIcon: Icons.receipt_long,
            builder: (context, logs, reload) => ListView.separated(
              itemCount: logs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final log = logs[i];
                return ListTile(
                  dense: true,
                  leading: StatusChip(
                    label: log.actionLabel,
                    color: _colorFor(log.action, context),
                    dense: true,
                  ),
                  title: Text(
                    log.summary ?? '-',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '${log.actorEmail ?? '-'} · ${Fmt.dateTime(log.createdAt)}'
                    '${log.ipAddress != null ? ' · ${log.ipAddress}' : ''}',
                    style: const TextStyle(fontSize: 11),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  static Color _colorFor(String action, BuildContext context) => switch (action) {
        'DELETE' || 'REJECT' || 'LOGIN_FAILED' => const Color(0xFFEF4444),
        'CREATE' || 'APPROVE' => const Color(0xFF10B981),
        'SETTING_CHANGE' => const Color(0xFFF59E0B),
        'LOGIN' || 'LOGOUT' => const Color(0xFF94A3B8),
        _ => Theme.of(context).colorScheme.primary,
      };
}

class _HealthTab extends StatelessWidget {
  const _HealthTab();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AdminRepository>();
    return AsyncView<(ServerHealth, SystemStats)>(
      load: () async {
        final results = await Future.wait([repo.health(), repo.stats()]);
        return (results[0] as ServerHealth, results[1] as SystemStats);
      },
      builder: (context, data, reload) {
        final (health, stats) = data;
        final wide = AppTheme.isWide(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          health.databaseOk
                              ? Icons.check_circle
                              : Icons.error,
                          color: health.databaseOk
                              ? const Color(0xFF10B981)
                              : const Color(0xFFEF4444),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          health.databaseOk ? '서버 정상' : '서버 이상',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _kv('버전', health.version),
                    _kv('환경', health.environment),
                    _kv('데이터베이스', health.database),
                    _kv('가동 시간', health.uptimeLabel),
                    _kv('서버 시각', Fmt.dateTime(health.serverTime)),
                    _kv('저장소 사용량', stats.storageLabel),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: wide ? 4 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: wide ? 1.9 : 1.5,
              children: [
                StatTile(
                  label: '사용 중인 계정',
                  value: '${stats.usersActive}명',
                  hint: '승인 대기 ${stats.usersPending}명',
                  icon: Icons.people_outline,
                  color: stats.usersPending > 0
                      ? const Color(0xFFF59E0B)
                      : null,
                ),
                StatTile(
                  label: 'AS 접수',
                  value: '${stats.ticketsTotal}건',
                  hint: '진행중 ${stats.ticketsOpen}건',
                  icon: Icons.build_outlined,
                ),
                StatTile(
                  label: '자산',
                  value: '${stats.assetsTotal}건',
                  icon: Icons.inventory_2_outlined,
                ),
                StatTile(
                  label: '예정 일정',
                  value: '${stats.eventsUpcoming}건',
                  hint: '게시글 ${stats.postsTotal}건',
                  icon: Icons.event,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('테이블 현황 (${stats.tables.length}개)',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    for (final t in stats.tables)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(t.table,
                                  style: const TextStyle(fontSize: 12)),
                            ),
                            Text('${t.rows}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      );
}
