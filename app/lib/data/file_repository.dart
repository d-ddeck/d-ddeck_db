import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/upload_image.dart';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../models/attachment.dart';
import '../models/common.dart';

/// 첨부파일.
///
/// 서버의 `attachments` 는 폴리모픽이라 한 벌의 호출로 AS 건·게시글·자산·매장
/// 어디에나 붙는다. 그래서 모듈마다 업로드 코드를 따로 두지 않고 여기 하나만
/// 둔다 - `entityType` 이 어디에 붙일지를 정한다.
class FileRepository {
  FileRepository(this._api);
  final ApiClient _api;

  /// 서버가 받아 주는 대상. 목록에 없는 값은 400 으로 거절당한다.
  static const serviceTicket = 'service_ticket';
  static const post = 'post';
  static const asset = 'asset';
  static const event = 'event';
  static const store = 'store';
  static const worklog = 'worklog';

  Future<List<Attachment>> listFor(
    String entityType,
    String entityId, {
    String? photoCategory,
  }) async {
    final res = await _api.get(
      '/files/by-entity/$entityType/$entityId',
      query: {'photo_category': photoCategory},
    );
    return (res as List? ?? [])
        .map((e) => Attachment.fromJson(asMap(e)))
        .toList();
  }

  /// 파일 한 개 올리기.
  ///
  /// 서버가 `multipart/form-data` 로 받고 1MB 씩 흘려 쓰면서 크기를 본다.
  /// 최대 크기는 서버 설정(MAX_UPLOAD_MB)이라 여기서 미리 막지 않고, 넘으면
  /// 서버가 주는 한글 메시지를 그대로 보여 준다.
  Future<Attachment> upload({
    required String entityType,
    required String entityId,
    required String filePath,
    required String fileName,
    String? photoCategory,
    void Function(int sent, int total)? onProgress,
  }) async {
    final extension = fileName.toLowerCase().split('.').last;
    final resized = ['jpg', 'jpeg', 'png', 'webp'].contains(extension)
        ? await compute(resizeUploadImage, filePath)
        : null;
    final upload = resized == null
        ? await MultipartFile.fromFile(filePath, filename: fileName)
        : MultipartFile.fromBytes(
            resized,
            filename: '${fileName.replaceFirst(RegExp(r'\.[^.]+$'), '')}.jpg',
          );
    final form = FormData.fromMap({
      if (photoCategory != null && photoCategory != 'general')
        'photo_category': photoCategory,
      'entity_type': entityType,
      'entity_id': entityId,
      'file': upload,
    });
    final res = await _api.postMultipart(
      '/files',
      form,
      onProgress: onProgress,
    );
    return Attachment.fromJson(asMap(res));
  }

  /// 내려받아 로컬 파일로 저장하고 그 경로를 돌려준다.
  ///
  /// 저장 위치는 OS 가 정하는 임시/문서 폴더다. 앱이 파일을 들고 있을 이유가
  /// 없으므로 열어 보고 나면 OS 가 치우게 둔다.
  Future<File> download(Attachment attachment) async {
    final bytes = await _api.getBytes('/files/${attachment.id}');
    final dir = await getTemporaryDirectory();
    final safe = attachment.originalName.replaceAll(RegExp(r'[/\\]'), '_');
    final file = File('${dir.path}/${attachment.id}_$safe');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> delete(String attachmentId) =>
      _api.delete('/files/$attachmentId');
}
