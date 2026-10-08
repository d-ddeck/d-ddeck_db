import '../common/section_main_reporter.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'board_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';
import '../theme.dart';

import '../../data/file_repository.dart';
import '../../data/board_repository.dart';
import '../../models/attachment.dart';
import '../../models/board.dart';
import '../../models/common.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../common/attachment_image.dart';
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
              if (boards.isEmpty)
                const Expanded(child: Center(child: Text('접근 가능한 게시판이 없습니다.'))),
              Row(
                children: [
                  if (boards.isNotEmpty)
                    Expanded(
                      child: TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        tabs: [
                          for (final b in boards)
                            WorkspaceTab(
                              text: b.name,
                              icon: Icon(b.displayIcon, size: 18),
                            ),
                        ],
                      ),
                    ),
                  if (context.watch<AuthState>().isAdmin)
                    IconButton(
                      tooltip: '게시판 관리',
                      icon: const Icon(Icons.settings),
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

    void resetSearch() {
      setState(() {
        _query = null;
        _search.clear();
      });
      _refresh();
    }

    Future<void> writePost() async {
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => PostFormPage(board: widget.board)),
      );
      if (created == true && mounted) _refresh();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(
              widget.board.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              SizedBox(
                width: (constraints.maxWidth * 0.4).clamp(100.0, 360.0),
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '제목 / 내용 검색',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) {
                    setState(() => _query = v.trim().isEmpty ? null : v.trim());
                    _refresh();
                  },
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              if (compact)
                IconButton(
                  tooltip: '초기화',
                  onPressed: resetSearch,
                  icon: const Icon(Icons.refresh),
                )
              else
                TextButton.icon(
                  onPressed: resetSearch,
                  icon: const Icon(Icons.refresh),
                  label: const Text('초기화'),
                ),
              const SizedBox(width: AppSpace.sm),
            ],
          ),
          body: PageBody.workspace(
            child: Column(
              children: [
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
                              padding: EdgeInsets.only(
                                bottom: canWrite ? 72 : 0,
                              ),
                              itemCount: page.items.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
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
                                        const Icon(
                                          Icons.lock_outline,
                                          size: 13,
                                        ),
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

          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButton: canWrite
              ? FloatingActionButton.extended(
                  heroTag: 'write-${widget.board.id}',
                  tooltip: '글쓰기',
                  onPressed: writePost,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('+'),
                )
              : null,
        );
      },
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
                    // 수정 · 삭제는 제목 줄 오른쪽 위.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            post.title,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
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
                                  if (saved == true && context.mounted) {
                                    reload();
                                  }
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
                                  if (ok && context.mounted) {
                                    Navigator.pop(context);
                                  }
                                },
                              ),
                            ],
                          ),
                      ],
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
                    // 사진은 본문 아래에 바로 보이고, 나머지 파일은 첨부 목록에.
                    // 글을 다시 불러오면(수정 후) 사진도 새로 받는다.
                    _PostImages(key: ObjectKey(post), postId: post.id),
                    const SizedBox(height: AppSpace.md),
                    AttachmentSection(
                      entityType: FileRepository.post,
                      entityId: post.id,
                      includeImages: false,
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
  // 새로 고른 파일은 글을 저장한 직후에 올린다. 이미지는 사진마다 코멘트를 단다.
  final List<_PostImage> _images = [];
  final List<PlatformFile> _files = [];
  // 수정 화면에서 뺀 저장된 사진. 저장에 성공하면 첨부에서도 지운다.
  final Set<String> _removedImages = {};
  bool _imagesLoading = false;
  String? _uploading;

  static const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

  bool _isImage(PlatformFile file) =>
      _imageExtensions.contains((file.extension ?? '').toLowerCase());

  Future<void> _pick({required bool images}) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: images ? FileType.image : FileType.any,
    );
    if (result == null || !mounted) return;
    setState(() {
      for (final f in result.files.where((f) => f.path != null)) {
        if (_isImage(f)) {
          if (!_images.any((i) => i.localPath == f.path)) {
            _images.add(_PostImage(localPath: f.path, name: f.name));
          }
        } else if (!_files.any((p) => p.path == f.path)) {
          _files.add(f);
        }
      }
    });
  }

  /// 수정 화면: 이미 올린 사진을 코멘트와 함께 불러온다.
  Future<void> _loadImages(String postId) async {
    setState(() => _imagesLoading = true);
    final repo = context.read<FileRepository>();
    await runGuarded(context, () async {
      final saved = await repo.listFor(FileRepository.post, postId);
      if (!mounted) return;
      setState(() {
        for (final a in saved.where((a) => a.isImage)) {
          _images.add(
            _PostImage(
              attachmentId: a.id,
              name: a.originalName,
              comment: a.comment,
            ),
          );
        }
      });
    });
    if (mounted) setState(() => _imagesLoading = false);
  }

  Widget _imageTile(_PostImage image) => SizedBox(
    width: 160,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            image.attachmentId != null
                ? AttachmentImage(
                    attachmentId: image.attachmentId!,
                    width: 160,
                    height: 120,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(image.localPath!),
                      width: 160,
                      height: 120,
                      fit: BoxFit.cover,
                      cacheWidth: 320,
                      errorBuilder: (_, _, _) => const SizedBox(
                        width: 160,
                        height: 120,
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
            Positioned(
              top: 2,
              right: 2,
              child: IconButton.filledTonal(
                tooltip: '사진 빼기',
                visualDensity: VisualDensity.compact,
                onPressed: _busy
                    ? null
                    : () {
                        setState(() {
                          _images.remove(image);
                          if (image.attachmentId != null) {
                            _removedImages.add(image.attachmentId!);
                          }
                        });
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => image.dispose(),
                        );
                      },
                icon: const Icon(Icons.close, size: 16),
              ),
            ),
          ],
        ),
        TextField(
          controller: image.comment,
          maxLength: 500,
          minLines: 1,
          maxLines: 2,
          decoration: const InputDecoration(
            hintText: '사진 코멘트',
            isDense: true,
            counterText: '',
          ),
        ),
      ],
    ),
  );

  Widget _attachments() {
    final post = widget.post;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: '사진',
          actions: [
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pick(images: true),
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: const Text('사진 추가'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_imagesLoading) const LinearProgressIndicator(),
              if (_images.isEmpty && !_imagesLoading)
                const Text('사진을 고르면 사진마다 코멘트를 달 수 있습니다'),
              if (_images.isNotEmpty)
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final i in _images) _imageTile(i)],
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        // 수정: 사진이 아닌 파일은 바로 올리고 지운다(상세 화면과 같다).
        if (post != null)
          AttachmentSection(
            entityType: FileRepository.post,
            entityId: post.id,
            includeImages: false,
          )
        else
          SectionCard(
            title: '파일',
            actions: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pick(images: false),
                icon: const Icon(Icons.attach_file, size: 18),
                label: const Text('파일'),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_files.isEmpty) const Text('파일을 고르면 등록할 때 함께 올라갑니다'),
                for (final file in _files)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      file.size < 1024 * 1024
                          ? '${(file.size / 1024).toStringAsFixed(0)} KB'
                          : '${(file.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                    ),
                    trailing: IconButton(
                      tooltip: '빼기',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _files.remove(file)),
                      icon: const Icon(Icons.close),
                    ),
                  ),
              ],
            ),
          ),
        if (_uploading != null) ...[
          const SizedBox(height: 8),
          Text(_uploading!),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    final post = widget.post;
    if (post != null) {
      _title.text = post.title;
      _content.text = post.content;
      _pinned = post.isPinned;
      _secret = post.isSecret;
      if (widget.board.allowAttachment) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _loadImages(post.id),
        );
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    for (final i in _images) {
      i.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return DirtyFormScope(
      busy: _busy,
      snapshot: () => [
        _title.text,
        _content.text,
        _pinned,
        _secret,
        for (final i in _images)
          '${i.attachmentId ?? i.localPath}:${i.comment.text}',
        _files.length,
        _removedImages.length,
      ].toString(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${widget.board.name} ${widget.post == null ? '글쓰기' : '수정'}',
          ),
          actions: [
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
              if (widget.board.allowAttachment) ...[
                const SizedBox(height: AppSpace.md),
                _attachments(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      AppSnack.show(context, '제목을 입력해 주세요.');
      return;
    }
    setState(() => _busy = true);
    final files = context.read<FileRepository>();
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
      final failed = <String>[];
      if (widget.board.allowAttachment) {
        final uploads = [
          for (final i in _images.where((i) => i.attachmentId == null))
            (i.localPath!, i.name, i.comment.text),
          for (final f in _files) (f.path!, f.name, null),
        ];
        for (var n = 0; n < uploads.length; n++) {
          final (path, name, comment) = uploads[n];
          if (mounted) {
            setState(
              () =>
                  _uploading = '첨부 올리는 중 ${n + 1} / ${uploads.length} · $name',
            );
          }
          try {
            await files.upload(
              entityType: FileRepository.post,
              entityId: saved.id,
              filePath: path,
              fileName: name,
              comment: comment,
            );
          } catch (_) {
            failed.add(name);
          }
        }
        // 저장된 사진은 코멘트가 바뀐 것만 고치고, 뺀 사진은 지운다.
        for (final i in _images.where(
          (i) => i.attachmentId != null && i.comment.text.trim() != i.original,
        )) {
          try {
            await files.updateComment(i.attachmentId!, i.comment.text);
          } catch (_) {
            failed.add('${i.name} 코멘트');
          }
        }
        for (final id in _removedImages) {
          try {
            await files.delete(id);
          } catch (_) {
            // 권한이 없거나 이미 지워졌으면 그대로 둔다. 게시글에는 영향 없음.
          }
        }
      }
      if (mounted && failed.isNotEmpty) {
        AppSnack.show(
          context,
          '게시글은 저장했지만 첨부 ${failed.length}개를 올리지 못했습니다: ${failed.join(', ')}. 게시글에서 다시 첨부해 주세요.',
        );
        return;
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
    setState(() {
      _busy = false;
      _uploading = null;
    });
    if (ok) Navigator.of(context).pop(true);
  }
}

/// 게시글 사진 하나: 저장된 첨부이거나, 저장할 때 올릴 기기 파일.
class _PostImage {
  _PostImage({
    this.attachmentId,
    this.localPath,
    required this.name,
    String comment = '',
  }) : original = comment.trim(),
       comment = TextEditingController(text: comment);

  final String? attachmentId;
  final String? localPath;
  final String name;
  final String original;
  final TextEditingController comment;

  void dispose() => comment.dispose();
}

/// 게시글 사진을 본문처럼 크게 펼쳐 보이고, 사진마다 코멘트를 붙인다.
class _PostImages extends StatefulWidget {
  const _PostImages({super.key, required this.postId});
  final String postId;

  @override
  State<_PostImages> createState() => _PostImagesState();
}

class _PostImagesState extends State<_PostImages> {
  late final Future<List<Attachment>> _images = context
      .read<FileRepository>()
      .listFor(FileRepository.post, widget.postId);

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Attachment>>(
    future: _images,
    builder: (context, snap) {
      final images = (snap.data ?? const <Attachment>[])
          .where((a) => a.isImage)
          .toList();
      if (images.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final image in images) ...[
              AttachmentImage(
                attachmentId: image.id,
                fileName: image.originalName,
                maxHeight: 520,
              ),
              if (image.comment.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    image.comment,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ),
              const SizedBox(height: AppSpace.lg),
            ],
          ],
        ),
      );
    },
  );
}
