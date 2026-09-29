part of 'admin_page.dart';

class _AuditTab extends StatefulWidget {
  const _AuditTab();

  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  final _viewKey = GlobalKey<AsyncViewState<List<AuditLog>>>();
  String? _action, _module, _query;
  int _page = 1;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AdminRepository>();
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  labelText: '감사 로그 검색',
                  prefixIcon: Icon(Icons.search),
                ),
                onSubmitted: (value) {
                  setState(() {
                    _query = value.trim();
                    _page = 1;
                  });
                  _viewKey.currentState?.reload();
                },
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _module,
              hint: const Text('모든 모듈'),
              items: [
                const DropdownMenuItem(value: null, child: Text('모든 모듈')),
                for (final entry in {
                  'AUTH': '로그인',
                  'SERVICE': '서비스',
                  'INVENTORY': '재고',
                  'STORE': '매장',
                  'BOARD': '게시판',
                  'CALENDAR': '일정',
                  'SYSTEM': '시스템',
                }.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) {
                setState(() {
                  _module = value;
                  _page = 1;
                });
                _viewKey.currentState?.reload();
              },
            ),
          ],
        ),
        FilterBar(
          appliedFilters: [
            if (_action != null) AuditLog.actionLabels[_action] ?? _action!,
          ],
          onReset: () {
            setState(() {
              _action = null;
              _module = null;
              _query = null;
              _page = 1;
            });
            _viewKey.currentState?.reload();
          },
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('전체'),
                  selected: _action == null,
                  onSelected: (_) => setState(() {
                    _page = 1;
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
                      _page = 1;
                      _action = entry.key;
                      _viewKey.currentState?.reload();
                    }),
                  ),
                ],
              ],
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: AsyncView<List<AuditLog>>(
            key: _viewKey,
            load: () => repo.auditLogs(
              page: _page,
              action: _action,
              module: _module,
              query: _query,
              size: 100,
            ),

            emptyMessage: '아직 등록된 기록이 없습니다',
            emptyIcon: Icons.receipt_long,
            builder: (context, logs, reload) => ListView.separated(
              itemCount: logs.length + 1,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == logs.length) {
                  return _PageButtons(
                    page: _page,
                    hasMore: logs.length == 100,
                    onChanged: (value) {
                      setState(() => _page = value);
                      reload();
                    },
                  );
                }
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

  static Color _colorFor(String action, BuildContext context) =>
      switch (action) {
        'DELETE' || 'REJECT' || 'LOGIN_FAILED' => const Color(0xFFEF4444),
        'CREATE' || 'APPROVE' => const Color(0xFF10B981),
        'SETTING_CHANGE' => const Color(0xFFF59E0B),
        'LOGIN' || 'LOGOUT' => const Color(0xFF94A3B8),
        _ => Theme.of(context).colorScheme.primary,
      };
}
