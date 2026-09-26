part of 'admin_page.dart';

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
          padding: EdgeInsets.zero,
          children: [
            SectionCard(
              title: '서버 상태',
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          health.databaseOk ? Icons.check_circle : Icons.error,
                          color: health.databaseOk
                              ? const Color(0xFF10B981)
                              : const Color(0xFFEF4444),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          health.databaseOk ? '서버 정상' : '서버 이상',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _kv('앱 버전', appVersion),
                    _kv('서버 버전', health.version),
                    _kv('스키마', health.schemaRevisions.join(', ')),
                    _kv(
                      '디스크 여유',
                      '${(health.diskFreeBytes / 1073741824).toStringAsFixed(1)} GB',
                    ),
                    _kv('최근 백업', '${health.backup['last_success_at'] ?? '없음'}'),
                    _kv(
                      '원격 백업 검증',
                      health.backup['remote_verified'] == true ? '완료' : '미완료',
                    ),
                    if (health.backup['overdue'] == true ||
                        health.backup['failed'] == true)
                      const Text(
                        '백업이 실패했거나 36시간 이상 성공 기록이 없습니다.',
                        style: TextStyle(color: Colors.red),
                      ),
                    FilledButton.tonal(
                      onPressed:
                          health.backup['state'] == 'running' ||
                              health.backup['requested'] == true
                          ? null
                          : () async {
                              final ok = await runGuarded(
                                context,
                                repo.requestBackup,
                                successMessage:
                                    '백업을 요청했습니다. 잠시 후 새로고침해 상태를 확인하세요.',
                              );
                              if (ok) reload();
                            },
                      child: const Text('지금 백업'),
                    ),
                    _kv('환경', health.environment),
                    _kv('데이터베이스', health.database),
                    _kv('가동 시간', health.uptimeLabel),
                    _kv('서버 시각', Fmt.dateTime(health.serverTime)),
                    _kv('저장소 사용량', stats.storageLabel),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),
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
            const SizedBox(height: AppSpace.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '테이블 현황 (${Fmt.number(stats.tables.length)}개)',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    for (final t in stats.tables)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                t.table,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Text(
                              Fmt.number(t.rows),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
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
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}
