import '../common/section_main_reporter.dart';
import '../common/save_attachment_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../common/form_attachments_page.dart';
import 'board_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';
import '../theme.dart';

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

      emptyMessage: '접근 가능한 게시판이 없습니다.',
      emptyIcon: Icons.forum_outlined,
      builder: (context, boards, reload) => DefaultTabController(
        length: boards.length,
        child: SectionMainReporter(
          child: Column(
            children: [
              if (context.watch<AuthState>().isAdmin)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('게시판 관리'),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const BoardSettingsPage(),
                        ),
                      );
                      if (context.mounted) reload();
                    },
                  ),
                ),
              if (boards.isEmpty)
                const Expanded(child: Center(child: Text('접근 가능한 게시판이 없습니다.'))),
              if (boards.isNotEmpty)
                TabBar(
                  isScrollable: boards.length > 3,
                  tabAlignment: boards.length > 3
                      ? TabAlignment.start
                      : TabAlignment.fill,
                  tabs: [
                    for (final b in boards)
                      Tab(text: b.name, icon: Icon(b.type.icon, size: 18)),
                  ],
                ),
              if (boards.isNotEmpty)
                Expanded(
                  child: TabBarView(
                    children: [for (final b in boards) _PostListTab(board: b)],
                  ),
                ),
            ],
          ),
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
  int _page = 1;
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Set<String> _read = {};
  String? _readKey;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthState>();
    final key =
        'board.read:${auth.serverUrl}:${auth.user?.id}:${widget.board.id}';
    if (_readKey == key) return;
    _readKey = key;
    SharedPreferences.getInstance()
        .then((prefs) {
          if (mounted && _readKey == key) {
            setState(() => _read = (prefs.getStringList(key) ?? []).toSet());
          }
        })
        .catchError((Object _) {});
  }

  Future<void> _markRead(String id) async {
    if (!mounted) return;
    setState(() => _read.add(id));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _readKey!,
        _read.toList().reversed.take(500).toList().reversed.toList(),
      );
    } catch (_) {
      /* Read badges remain available for this visit. */
    }
  }

  void _refresh() {
    _page = 1;
    _viewKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BoardRepository>();
    final auth = context.watch<AuthState>();
    final canWrite = widget.board.canWrite(auth.role);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.board.name),
        actions: [
          if (canWrite)
            FilledButton.icon(
              onPressed: () async {
                final created = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => PostFormPage(board: widget.board),
                  ),
                );
                if (created == true) _refresh();
              },
              icon: const Icon(Icons.edit),
              label: const Text('글쓰기'),
            ),
        ],
      ),
      body: PageBody(
        child: Column(
          children: [
            FilterBar(
              appliedFilters: [if (_query != null) '검색: $_query'],
              onReset: () {
                setState(() {
                  _query = null;
                  _search.clear();
                });
                _refresh();
              },
              children: [
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: '제목 / 내용 검색',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (v) => setState(() {
                      _query = v.trim().isEmpty ? null : v.trim();
                      _refresh();
                    }),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: AsyncView<PagedList<Post>>(
                key: _viewKey,
                load: () => repo.posts(
                  widget.board.id,
                  query: _query,
                  page: _page,
                  size: widget.board.pageSize,
                ),

                emptyMessage: _query == null
                    ? '아직 등록된 게시글이 없습니다'
                    : '검색 조건에 맞는 게시글이 없습니다',
                emptyIcon: Icons.article_outlined,
                builder: (context, page, reload) => Column(
                  children: [
                    if (page.items.isEmpty)
                      Expanded(
                        child: EmptyState(
                          message: _query == null
                              ? (canWrite
                                    ? '첫 게시글을 작성해 보세요.'
                                    : '아직 글이 없습니다. 이 게시판은 읽기 전용입니다.')
                              : '검색 결과가 없습니다.',
                          action: _query == null
                              ? null
                              : TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _query = null;
                                      _search.clear();
                                    });
                                    _refresh();
                                  },
                                  child: const Text('검색 초기화'),
                                ),
                        ),
                      ),
                    if (page.items.isNotEmpty)
                      Expanded(
                        child: ListView.separated(
                          itemCount: page.items.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final post = page.items[i];
                            return ListTile(
                              minTileHeight: 84,
                              leading: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    post.isPinned
                                        ? Icons.push_pin
                                        : Icons.article_outlined,
                                  ),
                                  if (!_read.contains(post.id))
                                    const Text(
                                      '안 읽음',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                ],
                              ),
                              onTap: () => Navigator.of(context)
                                  .push(
                                    MaterialPageRoute(
                                      builder: (_) => PostDetailPage(
                                        postId: post.id,
                                        board: widget.board,
                                        onViewed: () => _markRead(post.id),
                                      ),
                                    ),
                                  )
                                  .then((_) {
                                    reload();
                                  }),
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
                                        fontSize: 16,
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
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
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
                                  '${Fmt.relative(post.createdAt)} · 조회 ${Fmt.number(post.viewCount)} · 첨부 ${post.attachmentCount}개${post.isPinned ? ' · 공지' : ''}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '이전 페이지',
                          onPressed: _page <= 1
                              ? null
                              : () {
                                  setState(() => _page--);
                                  reload();
                                },
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Text(
                          '$_page / ${page.pages == 0 ? 1 : page.pages} · ${page.total}건',
                        ),
                        IconButton(
                          tooltip: '다음 페이지',
                          onPressed: !page.hasMore
                              ? null
                              : () {
                                  setState(() => _page++);
                                  reload();
                                },
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),

      // The write button only appears when the board's write_role allows it.
    );
  }
}

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    required this.postId,
    required this.board,
    this.onViewed,
  });
  final VoidCallback? onViewed;

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
      body: PageBody(
        child: AsyncView<Post>(
          key: _viewKey,
          load: () async {
            final post = await repo.post(widget.postId);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onViewed?.call();
            });
            return post;
          },
          builder: (context, post, reload) => Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (context.read<AuthState>().isManager ||
                        post.authorId == context.read<AuthState>().user?.id)
                      Wrap(
                        runSpacing: 12,
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            icon: const Icon(Icons.edit),
                            label: const Text('수정'),
                            onPressed: () async {
                              final saved = await Navigator.push<bool>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => PostFormPage(
                                    board: widget.board,
                                    post: post,
                                  ),
                                ),
                              );
                              if (saved == true && context.mounted) reload();
                            },
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('삭제'),
                            onPressed: () async {
                              if (!await ConfirmDialog.show(
                                context,
                                title: '게시글 삭제',
                                message: '이 게시글을 삭제하시겠습니까?',
                                confirmLabel: '삭제',
                              )) {
                                return;
                              }
                              if (!context.mounted) return;
                              final ok = await runGuarded(
                                context,
                                () => repo.deletePost(post.id),
                              );
                              if (ok && context.mounted) Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                    Text(
                      post.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
                    SectionCard(
                      title: '본문',
                      child: SelectableText(
                        post.content,
                        style: const TextStyle(fontSize: 14, height: 1.6),
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    AttachmentSection(
                      entityType: FileRepository.post,
                      entityId: post.id,
                    ),
                    const SizedBox(height: AppSpace.md),
                    if (widget.board.allowComment) ...[
                      Text(
                        '댓글 ${Fmt.number(post.comments.length)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
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
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    Fmt.relative(c.createdAt),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outline,
                                    ),
                                  ),
                                  if (c.isSecret) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.lock_outline, size: 11),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                c.content,
                                style: const TextStyle(fontSize: 13),
                              ),
                              if (context.read<AuthState>().isManager ||
                                  c.author?.id ==
                                      context.read<AuthState>().user?.id)
                                TextButton(
                                  child: const Text('댓글 삭제'),
                                  onPressed: () async {
                                    if (!await ConfirmDialog.show(
                                      context,
                                      title: '댓글 삭제',
                                      message: '댓글을 삭제하시겠습니까?',
                                      confirmLabel: '삭제',
                                    )) {
                                      return;
                                    }
                                    if (!context.mounted) return;
                                    if (await runGuarded(
                                          context,
                                          () => repo.deleteComment(c.id),
                                        ) &&
                                        context.mounted) {
                                      reload();
                                    }
                                  },
                                ),
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
                                post.id,
                                _comment.text.trim(),
                              ),
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
        ),
      ),
    );
  }
}

class PostFormPage extends StatefulWidget {
  const PostFormPage({super.key, required this.board, this.post});
  final Board board;
  final Post? post;

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
  void initState() {
    super.initState();
    final post = widget.post;
    if (post != null) {
      _title.text = post.title;
      _content.text = post.content;
      _pinned = post.isPinned;
      _secret = post.isSecret;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return DirtyFormScope(
      busy: _busy,
      snapshot: () => [_title.text, _content.text, _pinned, _secret].toString(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${widget.board.name} ${widget.post == null ? '글쓰기' : '수정'}',
          ),
          actions: [
            if (widget.board.allowAttachment)
              SaveAttachmentButton(
                onPressed: _busy ? null : () => _submit(attachments: true),
              ),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(widget.post == null ? '등록' : '저장'),
            ),
          ],
        ),
        body: PageBody(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              FormSection(
                title: '게시글',
                children: [
                  TextField(
                    controller: _title,
                    decoration: const InputDecoration(labelText: '제목 *'),
                  ),

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
                      title: const Text(
                        '상단 고정',
                        style: TextStyle(fontSize: 14),
                      ),
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit({bool attachments = false}) async {
    if (_title.text.trim().isEmpty) {
      AppSnack.show(context, '제목을 입력해 주세요.');
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(context, () async {
      final saved = await (widget.post != null
          ? context.read<BoardRepository>().updatePost(widget.post!.id, {
              'title': _title.text.trim(),
              'content': _content.text,
              'is_pinned': _pinned,
              'is_secret': _secret,
            })
          : context.read<BoardRepository>().createPost(
              widget.board.id,
              title: _title.text.trim(),
              content: _content.text,
              isPinned: _pinned,
              isSecret: _secret,
            ));
      if (mounted && attachments && widget.board.allowAttachment) {
        await FormAttachmentsPage.open(context, 'post', saved.id);
      }
      if (mounted) {
        AppSnack.saved(
          context,
          label: '게시글 ${saved.title}',
          detail: () => PostDetailPage(postId: saved.id, board: widget.board),
        );
      }
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }
}
