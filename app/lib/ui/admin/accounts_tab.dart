import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/auth_repository.dart';
import '../../models/user.dart';
import '../../state/auth_state.dart';
import '../theme.dart';

class AccountsTab extends StatefulWidget {
  const AccountsTab({super.key});

  @override
  State<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<AccountsTab> {
  final _search = TextEditingController();
  final _users = <UserProfile>[];
  final _busyUsers = <String>{};
  Timer? _debounce;
  String? _status;
  String _query = '';
  String? _error;
  int _page = 0;
  int _request = 0;
  bool _hasMore = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || !_hasMore)) return;
    final request = ++_request;
    final repo = context.read<AuthRepository>();
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _users.clear();
        _page = 0;
        _hasMore = false;
      }
    });
    try {
      final result = await repo.listUsers(
        page: more ? _page + 1 : 1,
        size: 50,
        query: _query.isEmpty ? null : _query,
        status: _status,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _users.addAll(result.items);
        _page = result.page;
        _hasMore = result.hasMore;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      final message = e is ApiException
          ? e.message
          : '계정 목록을 불러오지 못했습니다.';
      setState(() => _error = message);
      AppSnack.show(context, message);
    } finally {
      if (mounted && request == _request) {
        setState(() => _loading = false);
      }
    }
  }

  void _searchNow() {
    _debounce?.cancel();
    _query = _search.text.trim();
    _load();
  }

  Future<void> _delete(UserProfile user) async {
    if (_busyUsers.contains(user.id) ||
        user.id == context.read<AuthState>().user?.id) { return; }
    setState(() => _busyUsers.add(user.id));
    try {
      final confirmed = await ConfirmDialog.show(context, title: '계정 삭제',
        message: '${user.fullName} 계정을 삭제합니다. '
              '이 사람이 남긴 기록·이력은 그대로 남습니다.', confirmLabel: '삭제', destructive: true);
      if (confirmed != true || !mounted) return;
      final repo = context.read<AuthRepository>();
      final ok = await runGuarded(
        context,
        () => repo.deleteUser(user.id),
      );
      if (ok && mounted) {
        await _load();
        if (mounted) AppSnack.show(context, '${user.fullName} 계정을 삭제했습니다.');
      }
    } finally {
      if (mounted) setState(() => _busyUsers.remove(user.id));
    }
  }

  String _roleLabel(Role role) => switch (role) {
    Role.member => '일반',
    Role.manager => '팀장',
    Role.admin => '관리자',
    Role.superadmin => '최고 관리자',
  };

  Future<void> _edit(UserProfile user, String action) async {
    if (_busyUsers.contains(user.id)) return;
    if (action != 'position' && user.id == context.read<AuthState>().user?.id) return;
    setState(() => _busyUsers.add(user.id));
    try {
      final changes = <String, dynamic>{};
      late String title, message, success;
      if (action == 'role') {
        var selected = user.role;
        final role = await showDialog<Role>(context: context, builder: (dialogContext) =>
          StatefulBuilder(builder: (context, setDialogState) => ConfirmDialog.form(
            title: Text('${user.fullName} 권한 변경'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('팀장 이상: 장비 삭제·위치 관리·자료 관리 / 관리자: 승인·설정·계정'),
              for (final role in Role.values) RadioListTile<Role>(
                title: Text(_roleLabel(role)),
                value: role, groupValue: selected,
                onChanged: role == Role.superadmin ? null : (value) {
                  if (value != null) setDialogState(() => selected = value);
                },
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('취소')),
              FilledButton(
                onPressed: selected == user.role || selected == Role.superadmin
                    ? null : () => Navigator.pop(dialogContext, selected),
                child: const Text('다음')),
            ],
          )));
        if (role == null || !mounted) return;
        changes['role'] = role.value;
        title = '권한 변경';
        message = '${user.fullName} 권한을 ${_roleLabel(user.role)} → ${_roleLabel(role)}(으)로 변경합니다.';
        success = '${user.fullName} 권한을 변경했습니다.\n변경된 권한은 해당 사용자가 다시 로그인해야 반영됩니다.';
      } else if (action == 'status') {
        final suspended = user.status == UserStatus.suspended;
        changes['status'] = suspended ? 'APPROVED' : 'SUSPENDED';
        title = suspended ? '정지 해제' : '정지';
        message = suspended ? '${user.fullName} 계정의 정지를 해제합니다.'
            : '${user.fullName} 계정을 정지합니다. 이 계정의 모든 세션이 즉시 종료됩니다.';
        success = '${user.fullName} 계정을 ${suspended ? '정지 해제' : '정지'}했습니다.';
      } else if (action == 'position') {
        var position = user.position ?? '';
        final value = await showDialog<String>(context: context, builder: (dialogContext) =>
          ConfirmDialog.form(
            title: Text('${user.fullName} 직급 변경'),
            content: TextFormField(
              initialValue: position, autofocus: true, maxLength: 50,
              decoration: const InputDecoration(labelText: '직급',
                helperText: '근무일지에서 사용하는 직급과 같은 값을 입력하세요.'),
              onChanged: (value) => position = value,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('취소')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, position.trim()),
                child: const Text('다음')),
            ],
          ));
        if (value == null || !mounted || value == (user.position ?? '')) return;
        changes['position'] = value;
        title = '직급 변경';
        message = '${user.fullName} 직급을 ${value.isEmpty ? '미지정' : value}(으)로 변경합니다.';
        success = '${user.fullName} 직급을 변경했습니다.';
      } else {
        return;
      }
      if (!mounted) return;
      final confirmed = await ConfirmDialog.show(context, title: title,
        message: message, confirmLabel: title,
        destructive: changes['status'] == 'SUSPENDED');
      if (!confirmed || !mounted) return;
      final repo = context.read<AuthRepository>();
      final ok = await runGuarded(context, () async {
        await repo.updateUser(user.id, changes);
      });
      if (!ok || !mounted) return;
      await _load();
      if (mounted) AppSnack.show(context, success);
    } finally {
      if (mounted) setState(() => _busyUsers.remove(user.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selfId = context.watch<AuthState>().user?.id;
    return Column(
      children: [
        FilterBar(
          appliedFilters: [if (_query.isNotEmpty) '검색: $_query', if (_status != null)
            const {'APPROVED': '승인', 'SUSPENDED': '정지', 'PENDING': '대기'}[_status]!],
          onReset: () { _search.clear(); _status = null; _searchNow(); },
          children: [SizedBox(width: 360, child: TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: '이름·이메일 검색',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: '검색',
                onPressed: _searchNow,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _searchNow(),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), _searchNow);
            },
          )), Wrap(spacing: 6, runSpacing: 6,
              children: [
                for (final entry in const {
                  '': '전체',
                  'APPROVED': '승인',
                  'SUSPENDED': '정지',
                  'PENDING': '대기',
                }.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: (_status ?? '') == entry.key,
                      onSelected: (_) {
                        _status = entry.key.isEmpty ? null : entry.key;
                        _searchNow();
                      },
                    ),
                  ),
              ],
            )],
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading && _users.isEmpty
              ? const LoadingState()
              : RefreshIndicator(
                  onRefresh: () => _load(),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _users.length + 1,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      if (i == _users.length) return _footer();
                      final user = _users[i];
                      return ListTile(
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                user.fullName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 6),
                            StatusChip(
                              label: _roleLabel(user.role),
                              color: switch (user.role) {
                                Role.member => Colors.grey,
                                Role.manager => Colors.blue,
                                Role.admin => Colors.orange,
                                Role.superadmin => Colors.red,
                              },
                              dense: true,
                            ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.email,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12)),
                            Text(
                              '${user.status == UserStatus.approved ? '승인' : user.status.label}'
                              ' · 직급: ${user.position ?? '-'}'
                              ' · 부서: ${user.departmentName ?? '-'}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                                tooltip: '계정 메뉴',
                                enabled: !_busyUsers.contains(user.id),
                                icon: const Icon(Icons.more_vert),
                                onSelected: (action) => action == 'delete' ? _delete(user) : _edit(user, action),
                                itemBuilder: (_) => [
                                  if (user.id != selfId) ...[
                                    const PopupMenuItem(value: 'role', child: Text('권한 변경')),
                                    PopupMenuItem(value: 'status',
                                      child: Text(user.status == UserStatus.suspended ? '정지 해제' : '정지')),
                                  ],
                                  const PopupMenuItem(value: 'position', child: Text('직급 변경')),
                                  if (user.id != selfId)
                                    const PopupMenuItem(value: 'delete', child: Text('삭제')),
                                ],
                              ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _footer() {
    if (_loading) {
      return const LoadingState();
    }
    if (_error != null) {
      return ErrorState(
        message: _error!,
        onRetry: () => _load(more: _users.isNotEmpty),
      );
    }
    if (_users.isEmpty) {
      return const StatePlaceholder(
        icon: Icons.people_outline,
        message: '아직 등록된 계정이 없습니다',
      );
    }
    if (!_hasMore) return const SizedBox(height: 16);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextButton(
        onPressed: () => _load(more: true),
        child: const Text('더 보기'),
      ),
    );
  }
}
