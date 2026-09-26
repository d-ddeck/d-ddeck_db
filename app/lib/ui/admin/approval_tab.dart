part of 'admin_page.dart';

class _ApprovalTab extends StatefulWidget {
  const _ApprovalTab();

  @override
  State<_ApprovalTab> createState() => _ApprovalTabState();
}

class _ApprovalTabState extends State<_ApprovalTab> {
  final _viewKey = GlobalKey<AsyncViewState<PagedList<UserProfile>>>();
  int _page = 1;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AuthRepository>();
    return AsyncView<PagedList<UserProfile>>(
      key: _viewKey,
      load: () => repo.pendingUsers(page: _page, size: 50),

      emptyMessage: '승인 대기 중인 계정이 없습니다.',
      emptyIcon: Icons.how_to_reg,
      builder: (context, page, reload) => ListView.separated(
        itemCount: page.items.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == page.items.length) {
            return _PageButtons(
              page: _page,
              hasMore: _page * 50 < page.total,
              onChanged: (value) {
                setState(() => _page = value);
                reload();
              },
            );
          }
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (u.signupNote?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '"${u.signupNote}"',
                      style: const TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
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
                OutlinedButton(
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
    List<Department> departments = [];
    if (!await runGuarded(context, () async {
      departments = await repo.departments();
    })) {
      return;
    }
    if (!mounted) return;

    var role = Role.member;
    String? departmentId = user.departmentId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => ConfirmDialog.form(
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
                      enabled:
                          auth.role == Role.superadmin ||
                          r.level < auth.role.level,
                      child: Text(
                        r.label,
                        style: TextStyle(
                          color:
                              (auth.role == Role.superadmin ||
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
      builder: (ctx) => ConfirmDialog.form(
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
      () => context.read<AuthRepository>().reject(
        user.id,
        controller.text.trim(),
      ),
      successMessage: '반려 처리했습니다.',
    );
    if (ok) reload();
  }
}

/// Entry point to the six settings screens. One screen serves all of them.
