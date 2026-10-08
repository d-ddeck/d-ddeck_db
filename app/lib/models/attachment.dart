import 'common.dart';

/// 서버의 폴리모픽 첨부 한 줄.
///
/// `entityType` + `entityId` 로 AS 건·게시글·자산·매장 어디에나 붙는다.
/// 삭제는 소프트 삭제라 목록에서 빠질 뿐 디스크 파일은 남는다.
class Attachment {
  const Attachment({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.originalName,
    required this.sizeBytes,
    this.contentType,
    this.uploadedById,
    this.createdAt,
    this.comment = '',
  });

  final String id;
  final String entityType;
  final String entityId;
  final String originalName;
  final int sizeBytes;
  final String? contentType;
  final String? uploadedById;
  final DateTime? createdAt;

  /// 사진 설명 같은 짧은 코멘트. 없으면 빈 글자.
  final String comment;

  /// 확장자만. 아이콘을 고르는 데 쓴다.
  String get extension {
    final dot = originalName.lastIndexOf('.');
    return dot < 0 ? '' : originalName.substring(dot + 1).toLowerCase();
  }

  bool get isImage => const {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
  }.contains(extension);

  /// "2.4MB" 처럼. 목록에 바이트 수를 그대로 뿌리면 읽히지 않는다.
  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
    id: asString(j['id']),
    entityType: asString(j['entity_type']),
    entityId: asString(j['entity_id']),
    originalName: asString(j['original_name']),
    sizeBytes: asInt(j['size_bytes']),
    contentType: j['content_type'] as String?,
    uploadedById: j['uploaded_by_id'] as String?,
    comment: asString(j['comment']),
    createdAt: asDate(j['created_at']),
  );
}
