import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import 'common.dart';
import 'download.dart';

/// 서버에 올린 이미지 첨부를 바로 보여 준다. 누르면 원본을 연다.
///
/// [width]·[height] 를 주면 그 칸을 채워 자르고(썸네일), 주지 않으면 가로를 채우고
/// [maxHeight] 안에서 비율을 지킨다(게시글 본문 사진).
class AttachmentImage extends StatelessWidget {
  const AttachmentImage({
    super.key,
    required this.attachmentId,
    this.fileName,
    this.width,
    this.height,
    this.maxHeight = 480,
  });

  final String attachmentId;
  final String? fileName;
  final double? width, height;
  final double maxHeight;

  // 같은 사진을 화면마다 다시 받지 않는다.
  static final _cache = <String, Future<Uint8List>>{};

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final bytes = _cache.putIfAbsent(
      attachmentId,
      () async =>
          Uint8List.fromList(await api.getBytes('/files/$attachmentId')),
    );
    final thumb = width != null && height != null;
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snap) {
        if (snap.hasError) _cache.remove(attachmentId);
        final frame = Theme.of(context).colorScheme.surfaceContainerHighest;
        final Widget child;
        if (snap.hasData) {
          child = Image.memory(
            snap.data!,
            width: width,
            height: height,
            fit: thumb ? BoxFit.cover : BoxFit.contain,
            cacheWidth: thumb ? (width! * 2).round() : 1600,
            errorBuilder: (_, _, _) => const SizedBox(
              height: 120,
              child: Center(child: Icon(Icons.broken_image_outlined)),
            ),
          );
        } else {
          child = SizedBox(
            width: width,
            height: height ?? 200,
            child: Center(
              child: snap.hasError
                  ? const Icon(Icons.broken_image_outlined)
                  : const CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return InkWell(
          onTap: snap.hasData
              ? () => runGuarded(
                  context,
                  () => saveAndOpenDownload(
                    snap.data!,
                    fileName ?? '$attachmentId.jpg',
                  ),
                )
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: frame,
              constraints: thumb ? null : BoxConstraints(maxHeight: maxHeight),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
