import 'package:flutter/material.dart';
import 'attachment_section.dart';
import 'common.dart';

/// The record is already saved. Upload failures never repeat record creation.
class FormAttachmentsPage extends StatelessWidget {
  const FormAttachmentsPage({
    super.key,
    required this.entityType,
    required this.entityId,
  });
  final String entityType, entityId;
  static Future<void> open(BuildContext context, String type, String id) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => FormAttachmentsPage(entityType: type, entityId: id),
        ),
      );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('저장 완료 · 첨부파일')),
    body: PageBody(
      child: ListView(
        children: [
          const Text('내용이 저장되었습니다. 필요한 파일을 추가하세요.'),
          AttachmentSection(entityType: entityType, entityId: entityId),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('완료'),
          ),
        ],
      ),
    ),
  );
}
