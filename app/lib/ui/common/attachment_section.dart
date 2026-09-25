import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'common.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../data/file_repository.dart';
import '../../models/attachment.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';

class AttachmentSection extends StatelessWidget {
  const AttachmentSection({
    super.key,
    required this.entityType,
    required this.entityId,
  });

  final String entityType;
  final String entityId;

  @override
  Widget build(BuildContext context) => _AttachmentSectionBody(
    // 대상이 바뀌면 이전 목록과 진행 중인 작업의 UI 상태를 물려받지 않는다.
    key: ValueKey((entityType, entityId)),
    entityType: entityType,
    entityId: entityId,
  );
}

class _AttachmentSectionBody extends StatefulWidget {
  const _AttachmentSectionBody({
    super.key,
    required this.entityType,
    required this.entityId,
  });

  final String entityType;
  final String entityId;

  @override
  State<_AttachmentSectionBody> createState() => _AttachmentSectionBodyState();
}

class _AttachmentSectionBodyState extends State<_AttachmentSectionBody> {
  final _viewKey = GlobalKey<AsyncViewState<List<Attachment>>>();
  bool _adding = false;
  String? _busyId;
  String? _uploadName;
  int _uploadIndex = 0;
  int _uploadCount = 0;
  double? _progress;

  bool get _busy => _adding || _busyId != null;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<FileRepository>();
    final auth = context.watch<AuthState>();
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(title: '첨부', actions: [IconButton(
                  tooltip: '새로고침',
                  onPressed: _busy
                      ? null
                      : () => _viewKey.currentState?.reload(),
                  icon: const Icon(Icons.refresh),
                ), OutlinedButton.icon(
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.attach_file, size: 18),
                  label: const Text('추가'),
                )], child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            if (_adding) ...[
              const SizedBox(height: 8),
              if (_uploadName != null) ...[
                StatusChip(
                  label: '업로드 중 $_uploadIndex / $_uploadCount',
                  color: scheme.primary,
                ),
                const SizedBox(height: 6),
                Text(
                  _uploadName!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ] else
                const Text('파일 선택 중…'),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progress),
              if (_progress != null)
                Text(
                  '${(_progress! * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
            ],
            AsyncView<List<Attachment>>(
              key: _viewKey,
              load: () => repo.listFor(widget.entityType, widget.entityId),
              builder: (context, attachments, reload) {
                // 상세 화면의 스크롤 안에 있으므로 빈 목록도 높이가 정해진 ListView를 쓰지 않는다.
                if (attachments.isEmpty) {
                  return EmptyState(icon: Icons.attach_file, message: '아직 등록된 첨부파일이 없습니다',
                    action: OutlinedButton(onPressed: _busy ? null : _add, child: const Text('파일 추가')));
                }
                return Column(
                  children: [
                    for (final attachment in attachments)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _busyId == attachment.id
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                attachment.isImage
                                    ? Icons.image_outlined
                                    : Icons.insert_drive_file_outlined,
                              ),
                        title: Text(attachment.originalName),
                        subtitle: Text(
                          '${attachment.sizeLabel} · ${Fmt.dateTime(attachment.createdAt)}',
                        ),
                        onTap: _busy ? null : () => _open(attachment),
                        trailing:
                            auth.isAdmin ||
                                (auth.user != null &&
                                    auth.user!.id == attachment.uploadedById)
                            ? IconButton(
                                tooltip: '삭제',
                                onPressed: _busy
                                    ? null
                                    : () => _delete(attachment),
                                icon: const Icon(Icons.delete_outline),
                              )
                            : null,
                      ),
                  ],
                );
              },
            ),
          ],
        ));
  }

  Future<void> _add() async {
    final repo = context.read<FileRepository>();
    setState(() => _adding = true);
    try {
      FilePickerResult? selection;
      final picked = await runGuarded(context, () async {
        selection = await FilePicker.platform.pickFiles(allowMultiple: true);
      });
      if (!mounted || !picked || selection == null) return;
      final files = selection!.files;
      for (var i = 0; i < files.length; i++) {
        if (!mounted) break;
        final file = files[i];
        setState(() {
          _uploadName = file.name;
          _uploadIndex = i + 1;
          _uploadCount = files.length;
          _progress = null;
        });
        final ok = await runGuarded(context, () async {
          final path = file.path;
          if (path == null) {
            throw ApiException(
              code: 'FILE_PATH_UNAVAILABLE',
              message: '${file.name}: 파일 경로를 확인할 수 없습니다. 다시 선택해 주세요.',
            );
          }
          await repo.upload(
            entityType: widget.entityType,
            entityId: widget.entityId,
            filePath: path,
            fileName: file.name,
            onProgress: (sent, total) {
              if (!mounted) return;
              setState(() {
                _progress = total > 0 ? (sent / total).clamp(0.0, 1.0) : null;
              });
            },
          );
        });
        if (mounted && ok) _viewKey.currentState?.reload();
      }
    } finally {
      if (mounted) {
        setState(() {
          _adding = false;
          _uploadName = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _open(Attachment attachment) async {
    final repo = context.read<FileRepository>();
    setState(() => _busyId = attachment.id);
    try {
      await runGuarded(context, () async {
        final file = await repo.download(attachment);
        if (!mounted) return;
        final result = await OpenFilex.open(file.path);
        if (result.type != ResultType.done) {
          throw ApiException(
            code: 'FILE_OPEN_FAILED',
            message: switch (result.type) {
              ResultType.noAppToOpen => '이 파일을 열 수 있는 앱이 없습니다.',
              ResultType.fileNotFound => '다운로드한 파일을 찾을 수 없습니다.',
              ResultType.permissionDenied => '파일을 열 권한이 없습니다.',
              _ => '파일을 열지 못했습니다. 연결된 기본 앱을 확인해 주세요.',
            },
          );
        }
      });
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _delete(Attachment attachment) async {
    final repo = context.read<FileRepository>();
    setState(() => _busyId = attachment.id);
    try {
      final confirmed = await ConfirmDialog.show(context, title: '첨부파일 삭제',
        message: '${attachment.originalName}\n파일을 삭제하시겠습니까?', confirmLabel: '삭제', destructive: true);
      if (!mounted || confirmed != true) return;
      final ok = await runGuarded(
        context,
        () => repo.delete(attachment.id),
        successMessage: '삭제되었습니다.',
      );
      if (mounted && ok) _viewKey.currentState?.reload();
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }
}
