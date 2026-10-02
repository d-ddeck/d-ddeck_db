import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../data/service_repository.dart';
import '../../models/common.dart';
import '../../models/service.dart';
import '../common/common.dart';
import '../format.dart';
import '../theme.dart';

/// 상태 변경 창에서 받은 값. 종결이 아니면 처리 내용·서비스인원·서비스일은 비어 있다.
class StatusChangeInput {
  const StatusChangeInput({
    this.note,
    this.resultNote,
    this.responderIds,
    this.completedAt,
    this.workMinutes,
  });
  final String? note, resultNote;
  final List<String>? responderIds;
  final DateTime? completedAt;
  final int? workMinutes;
}

/// [next] 로 바꾸기 전에 필요한 값을 묻는다. 종결이면 처리 내용·서비스인원·서비스일이
/// 필수다. 취소하면 null.
Future<StatusChangeInput?> askStatusChange(
  BuildContext context,
  ServiceTicket ticket,
  ServiceStatus next,
) async {
  final requiresResult = next == ServiceStatus.completed;
  final responderIds = ticket.responders.map((r) => r.id).toSet();
  var responders = <CodeItem>[];
  if (requiresResult) {
    final loaded = await runGuarded(context, () async {
      responders = (await context.read<AdminRepository>().codeGroup(
        'SERVICE_RESPONDER',
        includeHistorical: true,
      )).items.toList();
    });
    if (!loaded || !context.mounted) return null;
  }
  final resultController = TextEditingController(text: ticket.resultNote);
  final noteController = TextEditingController();
  final minutesController = TextEditingController();
  final form = GlobalKey<FormState>();
  var completedAt = DateTime.now();
  final dialog = DialogRoute<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => ConfirmDialog.form(
        constraints: AppTheme.isWide(ctx)
            ? const BoxConstraints.tightFor(width: 560)
            : null,
        title: Text(
          requiresResult
              ? '종결 처리'
              : ticket.status == ServiceStatus.completed
              ? '다시 열기'
              : '${next.label}(으)로 변경',
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints.tightFor(
            width: AppTheme.isWide(ctx) ? 560 : MediaQuery.sizeOf(ctx).width,
          ),
          child: SingleChildScrollView(
            padding: fieldLabelInsets(ctx),
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (requiresResult) ...[
                    TextFormField(
                      controller: resultController,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: '서비스 내용 *'),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? '서비스 내용을 입력해 주세요.'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    FormField<bool>(
                      validator: (_) =>
                          responderIds.isEmpty ? '서비스인원을 선택해 주세요.' : null,
                      builder: (field) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('서비스인원 *'),
                          const FormGap(),
                          Wrap(
                            spacing: 8,
                            runSpacing: AppSpace.md,
                            children: [
                              for (final r in responders)
                                FilterChip(
                                  label: Text(r.name),
                                  selected: responderIds.contains(r.id),
                                  onSelected: (v) => update(() {
                                    v
                                        ? responderIds.add(r.id)
                                        : responderIds.remove(r.id);
                                  }),
                                ),
                            ],
                          ),
                          if (field.hasError)
                            Text(
                              field.errorText!,
                              style: TextStyle(
                                color: Theme.of(ctx).colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const FormGap(),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today),
                        label: Text('서비스일: ${Fmt.date(completedAt)}'),
                        onPressed: () async {
                          final date = await pickDate(
                            ctx,
                            completedAt,
                            firstDate: DateTime(1900),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (date != null && ctx.mounted) {
                            update(() => completedAt = date);
                          }
                        },
                      ),
                    ),
                    const FormGap(),
                  ],
                  TextFormField(
                    controller: noteController,
                    decoration: const InputDecoration(labelText: '변경 메모'),
                  ),
                  const FormGap(),
                  TextFormField(
                    controller: minutesController,
                    decoration: const InputDecoration(labelText: '작업 시간 (분)'),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.of(ctx).pop(true);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
  final confirmed = await Navigator.of(
    context,
    rootNavigator: true,
  ).push(dialog);
  await dialog.completed;
  final note = noteController.text.trim();
  final resultNote = resultController.text.trim();
  final minutes = int.tryParse(minutesController.text);
  noteController.dispose();
  resultController.dispose();
  minutesController.dispose();
  if (confirmed != true || !context.mounted) return null;
  return StatusChangeInput(
    note: note.isEmpty ? null : note,
    resultNote: requiresResult ? resultNote : null,
    responderIds: requiresResult ? responderIds.toList() : null,
    completedAt: requiresResult ? completedAt : null,
    workMinutes: minutes,
  );
}

/// 상태를 바꾸고 결과를 안내한다. 성공하면 바뀐 건을 돌려준다.
Future<ServiceTicket?> applyStatusChange(
  BuildContext context,
  String ticketId,
  ServiceStatus next,
  StatusChangeInput input,
) async {
  ServiceTicket? saved;
  await runGuarded(context, () async {
    saved = await context.read<ServiceRepository>().changeStatus(
      ticketId,
      next,
      note: input.note,
      resultNote: input.resultNote,
      responderIds: input.responderIds,
      completedAt: input.completedAt,
      workMinutes: input.workMinutes,
    );
    if (!context.mounted) return;
    AppSnack.show(
      context,
      saved!.notices.isEmpty
          ? (next == ServiceStatus.completed ? '종결 처리되었습니다.' : '상태가 변경되었습니다.')
          : saved!.notices.join('\n'),
    );
  });
  return saved;
}
