part of 'admin_page.dart';

class _SettingsHubTab extends StatelessWidget {
  const _SettingsHubTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
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
        if (context.watch<AuthState>().isAdmin)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('Google Drive 자동 백업'),
                subtitle: const Text(
                  '자동 백업 시간 · 연결 계정 변경 · 즉시 백업',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DriveBackupPage()),
                ),
              ),
            ),
          ),
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

  static const _icons = <SettingsModule, IconData>{
    SettingsModule.system: Icons.settings,
    SettingsModule.auth: Icons.verified_user_outlined,
    SettingsModule.service: Icons.build_outlined,
    SettingsModule.inventory: Icons.inventory_2_outlined,
    SettingsModule.board: Icons.forum_outlined,
    SettingsModule.calendar: Icons.calendar_month_outlined,
  };
  static IconData _iconFor(SettingsModule m) => _icons[m]!;

  static String _descriptionFor(SettingsModule m) => switch (m) {
    SettingsModule.system => '회사명, 시간대, 점검 모드',
    SettingsModule.auth => '가입 승인 정책, 로그인 잠금, 기본 권한',
    SettingsModule.service => '접수번호 규칙, 처리 기한, 서비스/세부분류/원인/조치 분류',
    SettingsModule.inventory => '자산번호 규칙, 안전재고 경고, 자산 분류',
    SettingsModule.board => '첨부 용량, 기본 목록 개수',
    SettingsModule.calendar => '기본 알림 시점, 업무 시간, 일정 유형',
  };
}
