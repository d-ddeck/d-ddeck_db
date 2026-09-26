import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../data/file_repository.dart';
import '../../data/worklog_repository.dart';
import '../../models/worklog.dart';
import '../common/attachment_section.dart';
import '../common/common.dart';
import '../format.dart';
import '../theme.dart';
import 'worklog_form_page.dart';

class WorkLogDetailPage extends StatefulWidget {
  const WorkLogDetailPage({super.key, required this.id});
  final String id;
  @override
  State<WorkLogDetailPage> createState() => _WorkLogDetailPageState();
}

class _WorkLogDetailPageState extends State<WorkLogDetailPage> {
  WorkLog? _log;
  String? _error;
  bool _loading = true, _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final log = await context.read<WorkLogRepository>().get(widget.id);
      if (mounted) setState(() => _log = log);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '오류가 발생했습니다: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: '근무일지 삭제',
      message: '근무일지를 삭제하시겠습니까? 첨부도 함께 지워집니다',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (!mounted || !confirmed) return;
    setState(() => _busy = true);
    final repo = context.read<WorkLogRepository>();
    final ok = await runGuarded(
      context,
      () => repo.delete(widget.id),
      successMessage: '삭제되었습니다.',
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final log = _log;
    return Scaffold(
      appBar: AppBar(
        title: Text(log == null ? '근무일지' : '${log.workDate} 근무일지'),
        actions: [
          if (log?.canEdit == true && !_loading && _error == null) ...[
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.of(context).push<String>(
                        MaterialPageRoute<String>(
                          builder: (_) => WorkLogFormPage(id: widget.id),
                        ),
                      );
                      if (mounted) await _load();
                    },
              child: const Text('수정'),
            ),
            IconButton(
              tooltip: '삭제',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
      body: _loading
          ? const LoadingState()
          : _error != null
          ? ErrorState(message: _error!, onRetry: _load)
          : SingleChildScrollView(
              child: PageBody(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${log!.workDate} 근무일지 · ${log.authorName} ${log.position} · ${log.workStart}~${log.workEnd}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (log.overtime) const Chip(label: Text('연장')),
                        if (log.visibility == 'TEAM')
                          const Chip(label: Text('팀 공개')),
                      ],
                    ),
                    const SizedBox(height: AppSpace.lg),
                    SectionCard(
                      title: '금일 업무',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SelectableText(
                            log.summary,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const FormGap(),
                          SelectableText(log.detail),
                          if (log.overtime) ...[
                            const FormGap(),
                            const Text('연장 근무 내용'),
                            SelectableText(log.overtimeNote),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    SectionCard(
                      title: '예정·요청',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('예정 업무'),
                          SelectableText(log.plan.isEmpty ? '-' : log.plan),
                          const FormGap(),
                          const Text('필요/요청사항'),
                          SelectableText(log.needs.isEmpty ? '-' : log.needs),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    AttachmentSection(
                      entityType: FileRepository.worklog,
                      entityId: log.id,
                      canEdit: log.canEdit,
                    ),
                    const SizedBox(height: AppSpace.md),
                    SectionCard(
                      title: '등록/수정 정보',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '작성자: ${log.author?.display ?? '${log.authorName} ${log.position}'}',
                          ),
                          Text(
                            '등록: ${log.createdBy?.display ?? '-'} · ${Fmt.dateTime(log.createdAt)}',
                          ),
                          Text(
                            '수정: ${log.updatedBy?.display ?? '-'} · ${Fmt.dateTime(log.updatedAt)}',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
