import '../async_view.dart';
import '../format.dart';
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
        if (!more) _users.clear();
        _users.addAll(result.items);
        _page = result.page;
        _hasMore = result.hasMore;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      if (e is ApiException && [401, 403].contains(e.statusCode)) {
        _users.clear();
      }
      final message = e is ApiException ? e.message : '계정 목록을 불러오지 못했습니다.';
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
        user.id == context.read<AuthState>().user?.id) {
      return;
    }
    setState(() => _busyUsers.add(user.id));
    try {
      final confirmed = await ConfirmDialog.show(
        context,
        title: '계정 삭제',
        message:
            '${user.fullName} 계정을 삭제합니다. '
            '이 사람이 남긴 기록·이력은 그대로 남습니다.',
        confirmLabel: '삭제',
        destructive: true,
      );
      if (confirmed != true || !mounted) return;
      final repo = context.read<AuthRepository>();
      final ok = await runGuarded(context, () => repo.deleteUser(user.id));
      if (ok && mounted) {
        await _load();
        if (mounted) AppSnack.show(context, '${user.fullName} 계정을 삭제했습니다.');
      }
    } finally {
      if (mounted) setState(() => _busyUsers.remove(user.id));
    }
  }

  Future<void> _detail(UserProfile user) async {
    final auth = context.read<AuthState>();
    final self = user.id == auth.user?.id;
    final canManage =
        auth.role == Role.superadmin || !user.role.atLeast(auth.role);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text('${user.fullName} · 계정 상세'),
        content: SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(user.email),
              const SizedBox(height: 12),
              Wrap(
                runSpacing: 12,
                spacing: 8,
                children: [
                  StatusChip(label: user.status.label),
                  StatusChip(label: _roleLabel(user.role)),
                ],
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('소속·직급'),
                subtitle: Text(
                  '${user.departmentName ?? '부서 미지정'} · ${user.position ?? '직급 미지정'}',
                ),
              ),
              Text('최근 로그인: ${Fmt.dateTime(user.lastLoginAt)}'),
              const SizedBox(height: 12),
              const Text(
                '로그인 기기·세션',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              if (canManage || self)
                AsyncView<List<Map<String, dynamic>>>(
                  load: () =>
                      context.read<AuthRepository>().userSessions(user.id),
                  builder: (_, sessions, reload) => Column(
                    children: [
                      if (sessions.isEmpty) const Text('활성 세션이 없습니다.'),
                      for (final row in sessions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.devices),
                          title: Text('${row['user_agent'] ?? '기기 정보 없음'}'),
                          subtitle: Text(
                            '${row['ip_address'] ?? '-'} · ${row['created_at'] ?? '-'}',
                          ),
                        ),
                    ],
                  ),
                )
              else
                const Text('동급·상위 계정의 세션은 조회할 수 없습니다.'),
              const SizedBox(height: 12),
              Wrap(
                runSpacing: 12,
                spacing: 8,
                children: [
                  for (final item in {
                    'name': '이름 변경',
                    'position': '직급 변경',
                    if (!self) 'role': '권한 변경',
                  }.entries)
                    OutlinedButton(
                      onPressed: canManage || (self && item.key != 'role')
                          ? () => Navigator.pop(ctx, item.key)
                          : null,
                      child: Text(item.value),
                    ),
                ],
              ),
              if (canManage && !self)
                ExpansionTile(
                  title: const Text('주의가 필요한 작업'),
                  subtitle: const Text('대상 계정과 영향을 확인한 후 실행하세요.'),
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'status'),
                      child: Text(
                        user.status == UserStatus.suspended ? '정지 해제' : '계정 정지',
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'reset'),
                      child: const Text('비밀번호 초기화 · 모든 세션 종료'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'delete'),
                      child: Text(
                        '계정 삭제',
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'delete') {
      await _delete(user);
    } else if (action == 'reset') {
      await _resetPassword(user);
    } else {
      await _edit(user, action);
    }
  }

  String _roleLabel(Role role) => switch (role) {
    Role.member => '일반',
    Role.manager => '팀장',
    Role.admin => '관리자',
    Role.superadmin => '최고 관리자',
  };

  Future<void> _resetPassword(UserProfile user) async {
    if (!await ConfirmDialog.show(
      context,
      title: '비밀번호 초기화',
      message: '${user.fullName}의 기존 세션을 종료하고 임시 비밀번호를 발급하시겠습니까?',
      confirmLabel: '초기화',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busyUsers.add(user.id));
    await runGuarded(context, () async {
      final message = await context.read<AuthRepository>().resetPassword(
        user.id,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('임시 비밀번호'),
          content: SelectableText('$message\n첫 로그인 때 비밀번호를 변경해야 합니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
    });
    if (mounted) setState(() => _busyUsers.remove(user.id));
  }

  Future<void> _edit(UserProfile user, String action) async {
    if (_busyUsers.contains(user.id)) return;
    if (!['position', 'name'].contains(action) &&
        user.id == context.read<AuthState>().user?.id) {
      return;
    }
    setState(() => _busyUsers.add(user.id));
    try {
      final changes = <String, dynamic>{};
      late String title, message, success;
      if (action == 'role') {
        var selected = user.role;
        final role = await showDialog<Role>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => ConfirmDialog.form(
              title: Text('${user.fullName} 권한 변경'),
              content: RadioGroup<Role>(
                groupValue: selected,
                onChanged: (value) {
                  if (value != null) setDialogState(() => selected = value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('팀장 이상: 장비 삭제·위치 관리·자료 관리 / 관리자: 승인·설정·계정'),
                    for (final role in Role.values)
                      RadioListTile<Role>(
                        title: Text(_roleLabel(role)),
                        value: role,
                        enabled: role != Role.superadmin,
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed:
                      selected == user.role || selected == Role.superadmin
                      ? null
                      : () => Navigator.pop(dialogContext, selected),
                  child: const Text('다음'),
                ),
              ],
            ),
          ),
        );
        if (role == null || !mounted) return;
        changes['role'] = role.value;
        title = '권한 변경';
        message =
            '${user.fullName} 권한을 ${_roleLabel(user.role)} → ${_roleLabel(role)}(으)로 변경합니다.';
        success = '${user.fullName} 권한을 변경했습니다.\n서버 권한 검사는 다음 요청부터 적용됩니다.';
      } else if (action == 'status') {
        final suspended = user.status == UserStatus.suspended;
        changes['status'] = suspended ? 'APPROVED' : 'SUSPENDED';
        title = suspended ? '정지 해제' : '정지';
        message = suspended
            ? '${user.fullName} 계정의 정지를 해제합니다.'
            : '${user.fullName} 계정을 정지합니다. 이 계정의 모든 세션이 즉시 종료됩니다.';
        success = '${user.fullName} 계정을 ${suspended ? '정지 해제' : '정지'}했습니다.';
      } else if (action == 'position' || action == 'name') {
        final editingName = action == 'name';
        final fieldLabel = editingName ? '이름' : '직급';
        var position = editingName ? user.fullName : user.position ?? '';
        final value = await showDialog<String>(
          context: context,
          builder: (dialogContext) => ConfirmDialog.form(
            title: Text('${user.fullName} $fieldLabel 변경'),
            content: TextFormField(
              initialValue: position,
              autofocus: true,
              maxLength: 50,
              decoration: InputDecoration(
                labelText: fieldLabel,
                helperText: '근무일지에서 사용하는 직급과 같은 값을 입력하세요.',
              ),
              onChanged: (value) => position = value,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, position.trim()),
                child: const Text('다음'),
              ),
            ],
          ),
        );
        if (value == null || !mounted || (editingName && value.isEmpty)) return;
        changes[editingName ? 'full_name' : 'position'] = value;
        title = '$fieldLabel 변경';
        message =
            '${user.fullName} $fieldLabel을 ${value.isEmpty ? '미지정' : value}(으)로 변경합니다.';
        success = '${user.fullName} $fieldLabel을 변경했습니다.';
      } else {
        return;
      }
      if (!mounted) return;
      final confirmed = await ConfirmDialog.show(
        context,
        title: title,
        message: message,
        confirmLabel: title,
        destructive: changes['status'] == 'SUSPENDED',
      );
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
          appliedFilters: [
            if (_query.isNotEmpty) '검색: $_query',
            if (_status != null)
              const {
                'APPROVED': '승인',
                'SUSPENDED': '정지',
                'PENDING': '대기',
              }[_status]!,
          ],
          onReset: () {
            _search.clear();
            _status = null;
            _searchNow();
          },
          children: [
            SizedBox(
              width: 360,
              child: TextField(
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
                  _debounce = Timer(
                    const Duration(milliseconds: 350),
                    _searchNow,
                  );
                },
              ),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
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
            ),
          ],
        ),
        const Divider(height: 1),
        if (_loading && _users.isNotEmpty)
          const LinearProgressIndicator(semanticsLabel: '이전 계정 목록을 표시하며 갱신 중'),
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
                        onTap: () => _detail(user),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                user.fullName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
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
                            Text(
                              user.email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
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
                          onSelected: (action) => action == 'delete'
                              ? _delete(user)
                              : action == 'reset'
                              ? _resetPassword(user)
                              : _edit(user, action),
                          itemBuilder: (_) => [
                            if (user.id != selfId) ...[
                              const PopupMenuItem(
                                value: 'role',
                                child: Text('권한 변경'),
                              ),
                              PopupMenuItem(
                                value: 'status',
                                child: Text(
                                  user.status == UserStatus.suspended
                                      ? '정지 해제'
                                      : '정지',
                                ),
                              ),
                            ],
                            const PopupMenuItem(
                              value: 'reset',
                              child: Text('비밀번호 초기화'),
                            ),
                            const PopupMenuItem(
                              value: 'name',
                              child: Text('이름 변경'),
                            ),
                            const PopupMenuItem(
                              value: 'position',
                              child: Text('직급 변경'),
                            ),
                            if (user.id != selfId)
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('삭제'),
                              ),
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
