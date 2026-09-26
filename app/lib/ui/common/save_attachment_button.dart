import 'package:flutter/material.dart';

/// Keep the action discoverable on desktop without crowding narrow app bars.
class SaveAttachmentButton extends StatelessWidget {
  const SaveAttachmentButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 700 ||
        MediaQuery.textScalerOf(context).scale(14) > 22) {
      return IconButton(
        tooltip: '저장 후 첨부파일 추가',
        onPressed: onPressed,
        icon: const Icon(Icons.attach_file),
      );
    }
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.attach_file),
      label: const Text('저장 후 첨부'),
    );
  }
}
