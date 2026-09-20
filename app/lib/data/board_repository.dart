import '../core/api_client.dart';
import '../models/board.dart';
import '../models/common.dart';

class BoardRepository {
  BoardRepository(this._api);
  final ApiClient _api;

  /// Only the boards this account may read, so the tab bar never shows a tab
  /// that would 403 when tapped.
  Future<List<Board>> boards() async {
    final res = await _api.get('/board/boards');
    return (res as List? ?? [])
        .map((e) => Board.fromJson(asMap(e)))
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  Future<PagedList<Post>> posts(
    String boardId, {
    int page = 1,
    int size = 20,
    String? query,
  }) async {
    final res = await _api.get('/board/boards/$boardId/posts',
        query: {'page': page, 'size': size, 'q': query});
    return PagedList.fromJson(res, Post.fromJson);
  }

  Future<Post> post(String postId) async =>
      Post.fromJson(asMap(await _api.get('/board/posts/$postId')));

  Future<Post> createPost(
    String boardId, {
    required String title,
    required String content,
    bool isPinned = false,
    bool isSecret = false,
  }) async {
    final res = await _api.post('/board/boards/$boardId/posts', body: {
      'title': title,
      'content': content,
      'is_pinned': isPinned,
      'is_secret': isSecret,
    });
    return Post.fromJson(asMap(res));
  }

  Future<Post> updatePost(String postId, Map<String, dynamic> changes) async {
    final res = await _api.patch('/board/posts/$postId', body: changes);
    return Post.fromJson(asMap(res));
  }

  Future<void> deletePost(String postId) =>
      _api.delete('/board/posts/$postId');

  Future<PostComment> addComment(String postId, String content,
      {bool isSecret = false}) async {
    final res = await _api.post('/board/posts/$postId/comments',
        body: {'content': content, 'is_secret': isSecret});
    return PostComment.fromJson(asMap(res));
  }

  Future<void> deleteComment(String commentId) =>
      _api.delete('/board/comments/$commentId');

  /// Saves a board's settings. This endpoint is the 게시판 설정창.
  Future<Board> updateBoard(String boardId, Map<String, dynamic> changes) async {
    final res = await _api.patch('/board/boards/$boardId', body: changes);
    return Board.fromJson(asMap(res));
  }
}
