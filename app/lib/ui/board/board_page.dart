import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/file_repository.dart';
import '../../data/board_repository.dart';
import '../../models/board.dart';
import '../../models/common.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../common/attachment_section.dart';
import '../format.dart';

/// 게시판. The board list doubles as the tab bar, and each Board object
/// carries its own rules (who may write, comments on/off, secret posts), so
/// this screen renders itself from the server's settings.
class BoardPage extends StatelessWidget {
  const BoardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BoardRepository>();
    return AsyncView<List<Board>>(
      load: repo.boards,
      emptyCheck: (b) => b.isEmpty,
      emptyMessage: '접근 가능한 게시판이 없습니다.',
      emptyIcon: Icons.forum_outlined,
      builder: (context, boards, reload) => DefaultTabController(
        length: boards.length,
        child: Column(
          children: [
            TabBar(
              isScrollable: boards.length > 3,
              tabAlignment:
                  boards.length > 3 ? TabAlignment.start : TabAlignment.fill,
              tabs: [
                for (final b in boards)
                  Tab(text: b.name, icon: Icon(b.type.icon, size: 18)),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [for (final b in boards) _PostListTab(board: b)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostListTab extends StatefulWidget {
  const _PostListTab({required this.board});
  final Board board;

  @override
  State<_PostListTab> createState() => _PostListTabState();
}

class _PostListTabState extends State<_PostListTab> {
  final _viewKey = GlobalKey<AsyncViewState<PagedList<Post>>>();
  String? _query;

  void _refresh() => _viewKey.currentState?.reload();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BoardRepository>();
    final auth = context.watch<AuthState>();
    final canWrite = widget.board.canWrite(auth.role);

    return Scaffold(
      appBar: AppBar(title: Text(widget.board.name), actions: [if (canWrite) FilledButton.icon(
        onPressed: () async {
                final created = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => PostFormPage(board: widget.board),
                  ),
                );
                if (created == true) _refresh();
              }, icon: const Icon(Icons.edit), label: const Text('글쓰기'))]),
      body: PageBody(child: Column(
        children: [
          FilterBar(appliedFilters: [if (_query != null) '검색: $_query'],
            onReset: () { setState(() => _query = null); _refresh(); },
            children: [SizedBox(width: 360, child: TextField(key: ValueKey(_query),
              decoration: const InputDecoration(
                hintText: '제목 / 내용 검색',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => setState(() {
                _query = v.trim().isEmpty ? null : v.trim();
                _refresh();
              }),
            ))]),
          const Divider(height: 1),
          Expanded(
            child: AsyncView<PagedList<Post>>(
              key: _viewKey,
              load: () => repo.posts(
                widget.board.id,
                query: _query,
                size: widget.board.pageSize,
              ),
              emptyCheck: (p) => p.isEmpty,
              emptyMessage: '아직 등록된 게시글이 없습니다',
              emptyIcon: Icons.article_outlined,
              builder: (context, page, reload) => ListView.separated(
                itemCount: page.items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final post = page.items[i];
                  return ListTile(
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(
                          builder: (_) => PostDetailPage(
                            postId: post.id,
                            board: widget.board,
                          ),
                        ))
                        .then((_) => reload()),
                    title: Row(
                      children: [
                        if (post.isPinned) ...[
                          const Icon(Icons.push_pin, size: 13),
                          const SizedBox(width: 4),
                        ],
                        if (post.isSecret) ...[
                          const Icon(Icons.lock_outline, size: 13),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            post.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: post.isPinned
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (post.commentCount > 0) ...[
                          const SizedBox(width: 6),
                          Text(
                            '[${post.commentCount}]',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '${post.author?.fullName ?? '-'} · '
                        '${Fmt.relative(post.createdAt)} · 조회 ${Fmt.number(post.viewCount)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      )),
      // The write button only appears when the board's write_role allows it.

    );
  }
}

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({super.key, required this.postId, required this.board});

  final String postId;
  final Board board;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  final _comment = TextEditingController();
  final _viewKey = GlobalKey<AsyncViewState<Post>>();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BoardRepository>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.board.name)),
      body: PageBody(child: AsyncView<Post>(
        key: _viewKey,
        load: () => repo.post(widget.postId),
        builder: (context, post, reload) => Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  Text(
                    post.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${post.author?.display ?? '-'} · '
                    '${Fmt.dateTime(post.createdAt)} · 조회 ${Fmt.number(post.viewCount)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Divider(height: 24),
                  SectionCard(title: '본문', child: SelectableText(post.content,
                      style: const TextStyle(fontSize: 14, height: 1.6))),
                  const SizedBox(height: 24),
                  AttachmentSection(
                    entityType: FileRepository.post,
                    entityId: post.id,
                  ),
                  const SizedBox(height: 24),
                  if (widget.board.allowComment) ...[
                    Text('댓글 ${Fmt.number(post.comments.length)}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    for (final c in post.comments)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  c.author?.display ?? '-',
                                  style: const TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  Fmt.relative(c.createdAt),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color:
                                        Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                                if (c.isSecret) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.lock_outline, size: 11),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(c.content,
                                style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
            if (widget.board.allowComment)
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _comment,
                          decoration: const InputDecoration(
                            hintText: '댓글 입력',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: () async {
                          if (_comment.text.trim().isEmpty) return;
                          final ok = await runGuarded(
                            context,
                            () => repo.addComment(
                                post.id, _comment.text.trim()),
                          );
                          if (ok) {
                            _comment.clear();
                            reload();
                          }
                        },
                        icon: const Icon(Icons.send, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      )),
    );
  }
}

class PostFormPage extends StatefulWidget {
  const PostFormPage({super.key, required this.board});
  final Board board;

  @override
  State<PostFormPage> createState() => _PostFormPageState();
}

class _PostFormPageState extends State<PostFormPage> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  bool _pinned = false;
  bool _secret = false;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.board.name} 글쓰기'),
        actions: [
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('등록'),
          ),
        ],
      ),
      body: PageBody(child: ListView(
        padding: EdgeInsets.zero,
        children: [
          FormSection(title: '게시글', children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: '제목 *'),
          ),
          const FormGap(),
          TextField(
            controller: _content,
            decoration: const InputDecoration(
              labelText: '내용',
              alignLabelWithHint: true,
            ),
            maxLines: 14,
          ),
          const SizedBox(height: 8),
          // Both toggles are gated by the board's own settings, so the form
          // never offers something the server would reject.
          if (auth.isManager)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('상단 고정', style: TextStyle(fontSize: 14)),
              value: _pinned,
              onChanged: (v) => setState(() => _pinned = v ?? false),
            ),
          if (widget.board.allowSecret)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('비밀글', style: TextStyle(fontSize: 14)),
              value: _secret,
              onChanged: (v) => setState(() => _secret = v ?? false),
            ),
          ]),
        ],
      )),
    );
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      AppSnack.show(context, '제목을 입력해 주세요.');
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => context.read<BoardRepository>().createPost(
            widget.board.id,
            title: _title.text.trim(),
            content: _content.text,
            isPinned: _pinned,
            isSecret: _secret,
          ),
      successMessage: '등록되었습니다.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }
}
