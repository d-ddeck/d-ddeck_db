import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/board_repository.dart';
import '../../models/board.dart';
import '../../models/user.dart';
import '../async_view.dart';
import '../common/common.dart';

class BoardSettingsPage extends StatefulWidget {
  const BoardSettingsPage({super.key});
  @override
  State<BoardSettingsPage> createState() => _BoardSettingsPageState();
}

class _BoardSettingsPageState extends State<BoardSettingsPage> {
  final _view = GlobalKey<AsyncViewState<List<Board>>>();
  Future<void> _edit([Board? board]) async {
    var name = board?.name ?? '', code = board?.code ?? '';
    var comment = board?.allowComment ?? true,
        attachment = board?.allowAttachment ?? true;
    var secret = board?.allowSecret ?? false,
        notify = board?.notifyOnPost ?? false,
        active = board?.isActive ?? true;
    var read = board?.readRole ?? Role.member,
        write = board?.writeRole ?? Role.member;
    var type = board?.type ?? BoardType.free, size = board?.pageSize ?? 20;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, change) => AlertDialog(
          title: Text(board == null ? '게시판 추가' : '게시판 설정'),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: FormFields(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (board == null)
                  TextFormField(
                    initialValue: code,
                    decoration: const InputDecoration(labelText: '코드'),
                    onChanged: (v) => code = v,
                  ),
                TextFormField(
                  initialValue: name,
                  decoration: const InputDecoration(labelText: '이름'),
                  onChanged: (v) => name = v,
                ),
                DropdownButtonFormField<BoardType>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: '유형'),
                  items: [
                    for (final v in BoardType.values)
                      DropdownMenuItem(value: v, child: Text(v.label)),
                  ],
                  onChanged: (v) => change(() => type = v!),
                ),
                for (final field in [(true, '읽기 권한'), (false, '쓰기 권한')])
                  DropdownButtonFormField<Role>(
                    initialValue: field.$1 ? read : write,
                    decoration: InputDecoration(labelText: field.$2),
                    items: [
                      for (final v in Role.values)
                        DropdownMenuItem(value: v, child: Text(v.label)),
                    ],
                    onChanged: (v) => change(() {
                      if (field.$1) {
                        read = v!;
                      } else {
                        write = v!;
                      }
                    }),
                  ),
                TextFormField(
                  initialValue: '$size',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '페이지 크기 (5~100)',
                  ),
                  onChanged: (v) => size = int.tryParse(v) ?? 20,
                ),
                SwitchListTile(
                  title: const Text('댓글 허용'),
                  value: comment,
                  onChanged: (v) => change(() => comment = v),
                ),
                SwitchListTile(
                  title: const Text('첨부 허용'),
                  value: attachment,
                  onChanged: (v) => change(() => attachment = v),
                ),
                SwitchListTile(
                  title: const Text('비밀글 허용'),
                  value: secret,
                  onChanged: (v) => change(() => secret = v),
                ),
                SwitchListTile(
                  title: const Text('새 글 알림'),
                  value: notify,
                  onChanged: (v) => change(() => notify = v),
                ),
                if (board != null)
                  SwitchListTile(
                    title: const Text('사용'),
                    value: active,
                    onChanged: (v) => change(() => active = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                if (name.trim().isNotEmpty &&
                    (board != null || code.trim().isNotEmpty) &&
                    size >= 5 &&
                    size <= 100) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final data = {
      'name': name.trim(),
      'type': type.value,
      'read_role': read.value,
      'write_role': write.value,
      'allow_comment': comment,
      'allow_attachment': attachment,
      'allow_secret': secret,
      'notify_on_post': notify,
      'page_size': size,
      if (board == null) 'code': code.trim() else 'is_active': active,
    };
    final repo = context.read<BoardRepository>();
    if (await runGuarded(context, () async {
      if (board == null) {
        await repo.createBoard(data);
      } else {
        await repo.updateBoard(board.id, data);
      }
    })) {
      _view.currentState?.reload();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('게시판 관리'),
      actions: [
        IconButton(onPressed: () => _edit(), icon: const Icon(Icons.add)),
      ],
    ),
    body: PageBody(
      child: AsyncView<List<Board>>(
        key: _view,
        load: () =>
            context.read<BoardRepository>().boards(includeInactive: true),
        builder: (context, boards, reload) => ListView(
          children: [
            for (final board in boards)
              ListTile(
                title: Text(board.name),
                subtitle: Text(
                  '${board.type.label} · ${board.isActive ? '사용' : '사용 안 함'}',
                ),
                onTap: () => _edit(board),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (!await ConfirmDialog.show(
                      context,
                      title: '게시판 삭제',
                      message: '${board.name} 게시판을 삭제하시겠습니까?',
                      confirmLabel: '삭제',
                    )) {
                      return;
                    }
                    if (!context.mounted) return;
                    if (await runGuarded(
                          context,
                          () => context.read<BoardRepository>().deleteBoard(
                            board.id,
                          ),
                        ) &&
                        context.mounted) {
                      reload();
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
