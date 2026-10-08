import 'package:flutter/material.dart';

import '../common/attachment_image.dart';

/// 업무 사진(이미 올린 첨부) 미리보기. 누르면 원본을 연다.
class TaskPhotoThumb extends StatelessWidget {
  const TaskPhotoThumb({
    super.key,
    required this.attachmentId,
    this.width = 160,
    this.height = 120,
  });

  final String attachmentId;
  final double width, height;

  @override
  Widget build(BuildContext context) => AttachmentImage(
    attachmentId: attachmentId,
    width: width,
    height: height,
  );
}
