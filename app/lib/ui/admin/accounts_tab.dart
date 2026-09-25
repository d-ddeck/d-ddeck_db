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
  final _deleting = <String>{};
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
    if (_deleting.contains(user.id) ||
        user.id == context.read<AuthState>().user?.id) { return; }
    setState(() => _deleting.add(user.id));
    try {
      final confirmed = await ConfirmDialog.show(context, title: '계정 삭제',
        message: '${user.fullName} 계정을 삭제합니다. '
              '이 사람이 남긴 기록·이력은 그대로 남습니다.', confirmLabel: '삭제', destructive: true);
      if (confirmed != true || !mounted) return;
      final repo = context.read<AuthRepository>();
      final ok = await runGuarded(
        context,
        () => repo.deleteUser(user.id),
        successMessage: '${user.fullName} 계정을 삭제했습니다.',
      );
      if (ok && mounted) await _load();
    } finally {
      if (mounted) setState(() => _deleting.remove(user.id));
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
                              label: user.role.label,
                              color: Theme.of(context).colorScheme.primary,
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
                        trailing: user.id == selfId
                            ? null
                            : PopupMenuButton<String>(
                                tooltip: '계정 메뉴',
                                enabled: !_deleting.contains(user.id),
                                icon: const Icon(Icons.more_vert),
                                onSelected: (_) => _delete(user),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: 'delete', child: Text('삭제')),
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
