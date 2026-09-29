import 'package:flutter/material.dart';

import 'common.dart';
import 'user.dart';

enum BoardType {
  notice('NOTICE', '공지', Icons.campaign),
  free('FREE', '자유', Icons.forum),
  qna('QNA', '질문', Icons.help_outline),
  archive('ARCHIVE', '자료실', Icons.folder_open);

  const BoardType(this.value, this.label, this.icon);
  final String value;
  final String label;
  final IconData icon;

  static BoardType parse(String? v) => BoardType.values.firstWhere(
    (t) => t.value == v,
    orElse: () => BoardType.free,
  );
}

enum BoardIcon {
  auto('auto', '유형 기본', Icons.auto_awesome),
  notice('notice', '공지', Icons.campaign),
  chat('chat', '대화', Icons.forum),
  question('question', '질문', Icons.help_outline),
  folder('folder', '자료실', Icons.folder_open),
  calendar('calendar', '일정', Icons.calendar_month),
  equipment('equipment', '장비', Icons.precision_manufacturing_outlined),
  store('store', '매장', Icons.store_outlined),
  document('document', '문서', Icons.description_outlined),
  task('task', '업무', Icons.assignment_outlined),
  idea('idea', '아이디어', Icons.lightbulb_outline),
  photo('photo', '사진', Icons.photo_library_outlined),
  team('team', '팀', Icons.groups_outlined);

  const BoardIcon(this.value, this.label, this.icon);
  final String value, label;
  final IconData icon;
  static BoardIcon parse(String? value) => BoardIcon.values.firstWhere(
    (item) => item.value == value,
    orElse: () => BoardIcon.auto,
  );
}

/// A board row IS that board's settings record, so the UI reads its own rules
/// straight off this object: whether to show the write button, the comment box,
/// the attachment button and the secret-post checkbox.
class Board {
  const Board({
    required this.id,
    required this.code,
    required this.name,
    required this.type,
    required this.readRole,
    required this.writeRole,
    this.description,
    this.icon = BoardIcon.auto,
    this.allowComment = true,
    this.allowAttachment = true,
    this.allowSecret = false,
    this.notifyOnPost = false,
    this.pageSize = 20,
    this.sortOrder = 0,
    this.isActive = true,
  });

  final String id;
  final String code;
  final String name;
  final BoardType type;
  final BoardIcon icon;
  IconData get displayIcon => icon == BoardIcon.auto ? type.icon : icon.icon;
  final Role readRole;
  final Role writeRole;
  final String? description;
  final bool allowComment;
  final bool allowAttachment;
  final bool allowSecret;
  final bool notifyOnPost;
  final int pageSize;
  final int sortOrder;
  final bool isActive;

  bool canWrite(Role role) => role.atLeast(writeRole);

  factory Board.fromJson(Map<String, dynamic> j) => Board(
    id: asString(j['id']),
    code: asString(j['code']),
    name: asString(j['name']),
    type: BoardType.parse(j['type'] as String?),
    icon: BoardIcon.parse(j['icon'] as String?),
    readRole: Role.parse(j['read_role'] as String?),
    writeRole: Role.parse(j['write_role'] as String?),
    description: j['description'] as String?,
    allowComment: asBool(j['allow_comment'], true),
    allowAttachment: asBool(j['allow_attachment'], true),
    allowSecret: asBool(j['allow_secret']),
    notifyOnPost: asBool(j['notify_on_post']),
    pageSize: asInt(j['page_size'], 20),
    sortOrder: asInt(j['sort_order']),
    isActive: asBool(j['is_active'], true),
  );
}

class PostComment {
  const PostComment({
    required this.id,
    required this.content,
    this.author,
    this.isSecret = false,
    this.createdAt,
  });

  final String id;
  final String content;
  final UserBrief? author;
  final bool isSecret;
  final DateTime? createdAt;

  factory PostComment.fromJson(Map<String, dynamic> j) => PostComment(
    id: asString(j['id']),
    content: asString(j['content']),
    author: j['author'] is Map ? UserBrief.fromJson(asMap(j['author'])) : null,
    isSecret: asBool(j['is_secret']),
    createdAt: asDate(j['created_at']),
  );
}

class Post {
  const Post({
    required this.id,
    required this.boardId,
    required this.title,
    this.content = '',
    this.author,
    this.authorId,
    this.isPinned = false,
    this.isSecret = false,
    this.viewCount = 0,
    this.attachmentCount = 0,
    this.commentCount = 0,
    this.createdAt,
    this.comments = const [],
  });

  final String id;
  final String boardId;
  final String title;
  final String content;
  final UserBrief? author;
  final String? authorId;
  final bool isPinned;
  final bool isSecret;
  final int viewCount;
  final int attachmentCount;
  final int commentCount;
  final DateTime? createdAt;
  final List<PostComment> comments;

  factory Post.fromJson(Map<String, dynamic> j) => Post(
    id: asString(j['id']),
    boardId: asString(j['board_id']),
    title: asString(j['title']),
    content: asString(j['content']),
    authorId: j['author_id'] as String?,
    author: j['author'] is Map ? UserBrief.fromJson(asMap(j['author'])) : null,
    isPinned: asBool(j['is_pinned']),
    isSecret: asBool(j['is_secret']),
    viewCount: asInt(j['view_count']),
    attachmentCount: asInt(j['attachment_count']),
    commentCount: asInt(j['comment_count']),
    createdAt: asDate(j['created_at']),
    comments: asList(j['comments'], PostComment.fromJson),
  );
}
