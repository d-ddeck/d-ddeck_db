import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/file_repository.dart';
import '../../data/admin_repository.dart';
import '../../models/common.dart';
import '../store/store_detail_page.dart';
import '../../data/service_repository.dart';
import '../../models/service.dart';
import '../async_view.dart';
import '../common/attachment_section.dart';
import '../format.dart';
import '../theme.dart';
import 'service_form_page.dart';
import 'service_feedback.dart';

class ServiceDetailPage extends StatefulWidget {
  const ServiceDetailPage({super.key, required this.ticketId});
  final String ticketId;

  @override
  State<ServiceDetailPage> createState() => _ServiceDetailPageState();
}

class _ServiceDetailPageState extends State<ServiceDetailPage> {
  final _viewKey = GlobalKey<AsyncViewState<ServiceTicket>>();
  bool _changed = false;

  /// 앱바의 수정 버튼이 집어 갈 현재 건. builder 안에서만 알 수 있어 들고 있는다.
  ServiceTicket? _current;

  /// builder 가 만든 화면을 그대로 돌려주면서 현재 건만 기억한다.
  Widget _wrap(ServiceTicket t, Widget child) {
    _current = t;
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ServiceRepository>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AS 상세'),
          actions: [
            IconButton(
              tooltip: '내용 수정',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final t = _current;
                if (t == null) return;
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => ServiceFormPage(ticket: t),
                  ),
                );
                if (saved == true) {
                  _changed = true;
                  _viewKey.currentState?.reload();
                }
              },
            ),
          ],
        ),
        body: PageBody(child: AsyncView<ServiceTicket>(
          key: _viewKey,
          load: () => serviceLoad(context, () => repo.get(widget.ticketId)),
          builder: (context, t, reload) => _wrap(t, ListView(
            padding: EdgeInsets.zero,
            children: [
              Wrap(
                spacing: 6, runSpacing: 6,
                children: [
                  StatusChip(label: t.status.label, color: t.status.color),
                  const SizedBox(width: 6),
                  StatusChip(
                      label: t.priority.label, color: t.priority.color),
                  const SizedBox(width: 6),
                  StatusChip(
                    label: t.isWarranty ? '보증' : '유상',
                    color: t.isWarranty
                        ? const Color(0xFF10B981)
                        : const Color(0xFF94A3B8),
                  ),
                  if (t.isOverdue) ...[
                    const SizedBox(width: 6),
                    const StatusChip(label: '지연', color: Color(0xFFEF4444)),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                t.title,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                t.displayNo,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),

              SectionCard(title: '기본 정보', child: ListTile(
                title: Text('${t.storeName ?? t.store?.name ?? '매장 미지정'} · ${t.brandName ?? t.store?.brandName ?? '-'}'),
                subtitle: Text('발생일 ${Fmt.date(t.receivedAt.toLocal())} · 과실 ${t.fault?.name ?? '-'}'),
                trailing: t.storeId == null ? null : const Icon(Icons.chevron_right),
                onTap: t.storeId == null ? null : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => StoreDetailPage(storeId: t.storeId!))),
              )),
              _TextCard(title: '원인 · 서비스구분 · 증상 · 제조사', body: t.causes.isEmpty
                ? (t.causeLabels.isEmpty ? '-' : t.causeLabels.join('\n'))
                : t.causes.map((c) => '${c.category?.name ?? '-'}${c.symptom == null ? '' : ' > ${c.symptom!.name}'}${c.maker == null ? '' : ' (${c.maker!.name})'}').join('\n')),
              SectionCard(title: '대응인원', child: Wrap(spacing: 8, children: [for (final r in t.responders) Chip(label: Text(r.name))])),
              if (t.isRental) ...[
                _InfoCard(title: '렌탈', rows: [
                  ('종류', t.rentalType?.name ?? '-'), ('시리얼', t.rentalSerials ?? '-'),
                  ('회수 예정일', Fmt.date(t.rentalDueDate)), ('회수 여부', t.rentalReturned ? '회수 완료' : '미회수'),
                  ('실제 회수일', Fmt.date(t.rentalReturnDate)),
                ]),
                if (!t.rentalReturned && t.rentalDueDate != null)
                  Padding(padding: const EdgeInsets.all(12), child: Text(
                    '렌탈 미회수 · ${_ddayLabel(t.rentalDueDate!)}',
                    style: TextStyle(fontWeight: FontWeight.w700, color: _daysLeft(t.rentalDueDate!) <= 0 ? AppColors.danger(context) : Theme.of(context).colorScheme.primary))),
              ],
              const SizedBox(height: 12),
              _InfoCard(
                title: '접수 정보',
                rows: [
                  ('거래처', t.customerLabel),
                  ('연락처', t.contactPhone ?? '-'),
                  ('현장 주소', t.siteAddress ?? '-'),
                  ('접수 경로', t.channel.label),
                  ('접수 일시', Fmt.dateTime(t.receivedAt.toLocal())),
                  ('처리 기한', Fmt.dateTime(t.dueAt)),
                  ('담당자', t.assignee?.display ?? '미배정'),
                ],
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: '대상 장비',
                rows: [
                  ('제품명', t.productName ?? '-'),
                  ('모델', t.modelName ?? '-'),
                  ('시리얼', t.serialNo ?? '-'),
                ],
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: '처리 현황',
                rows: [
                  ('착수', Fmt.dateTime(t.startedAt)),
                  ('완료', Fmt.dateTime(t.completedAt)),
                  ('소요 시간', Fmt.duration(t.resolutionMinutes)),
                  ('작업 시간', Fmt.duration(t.workMinutes)),
                  ('부품비', Fmt.money(t.partsCost)),
                  ('총 비용', Fmt.money(t.totalCost)),
                ],
              ),

              if (t.description?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                _TextCard(title: '접수 내용', body: t.description!),
              ],
              if (t.resultNote?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                _TextCard(title: '처리 결과', body: t.resultNote!),
              ],

              if (t.parts.isNotEmpty) ...[
                const SizedBox(height: 12),
                SectionCard(title: '사용 부품', child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        for (final p in t.parts)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Expanded(child: Text(p.partName)),
                                Text('${Fmt.number(p.quantity)}개'),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 96,
                                  child: Text(
                                    Fmt.money(p.lineTotal),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    )),
              ],

              const SizedBox(height: 12),
              SectionCard(title: '처리 이력', child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      if (t.logs.isEmpty)
                        const EmptyState(message: '아직 등록된 처리 이력이 없습니다')
                      else
                        for (final log in t.logs) _LogRow(log: log),
                    ],
                  )),

              const SizedBox(height: 12),
              AttachmentSection(
                entityType: FileRepository.serviceTicket,
                entityId: t.id,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (t.status.isOpen)
                    FilledButton.icon(onPressed: () => _changeStatus(t, ServiceStatus.completed, reload),
                      icon: const Icon(Icons.check), label: const Text('종결 처리')),
                  if (t.status == ServiceStatus.completed)
                    OutlinedButton(onPressed: () => _changeStatus(t, ServiceStatus.inProgress, reload), child: const Text('다시 열기')),
                  for (final next in t.status.nextOptions.where((s) => s != ServiceStatus.completed && t.status != ServiceStatus.completed))
                    OutlinedButton.icon(
                      onPressed: () => _changeStatus(t, next, reload),
                      icon: Icon(Icons.arrow_forward, size: 15,
                          color: next.color),
                      label: Text('${next.label}(으)로'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => _addLog(t.id, reload),
                    icon: const Icon(Icons.note_add_outlined, size: 15),
                    label: const Text('작업 기록'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          )),
        )),
      ),
    );
  }

  Future<void> _changeStatus(
    ServiceTicket ticket,
    ServiceStatus next,
    VoidCallback reload,
  ) async {
    final requiresResult = next == ServiceStatus.completed;
    final responderIds = ticket.responders.map((r) => r.id).toSet();
    var responders = <CodeItem>[];
    if (requiresResult) {
      final loaded = await runGuarded(context, () async {
        responders = (await context.read<AdminRepository>().codeGroup('SERVICE_RESPONDER')).items
            .where((r) => r.isActive || responderIds.contains(r.id)).toList();
      });
      if (!loaded || !mounted) return;
    }
    final resultController = TextEditingController(text: ticket.resultNote);
    final noteController = TextEditingController();
    final minutesController = TextEditingController();
    final form = GlobalKey<FormState>();
    var completedAt = DateTime.now();
    final dialog = DialogRoute<bool>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => ConfirmDialog.form(
        title: Text(requiresResult ? '종결 처리' : ticket.status == ServiceStatus.completed ? '다시 열기' : '${next.label}(으)로 변경'),
        content: SizedBox(width: AppTheme.isWide(ctx) ? 520 : double.maxFinite,
          child: SingleChildScrollView(child: Form(key: form, child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (requiresResult) ...[
              TextFormField(controller: resultController, maxLines: 4,
                decoration: const InputDecoration(labelText: '대응 내용 *'),
                validator: (v) => v == null || v.trim().isEmpty ? '대응 내용을 입력해 주세요.' : null),
              const SizedBox(height: 12),
              FormField<bool>(validator: (_) => responderIds.isEmpty ? '대응인원을 선택해 주세요.' : null,
                builder: (field) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('대응인원 *'),
                  Wrap(spacing: 8, children: [for (final r in responders)
                    FilterChip(label: Text(r.name), selected: responderIds.contains(r.id), onSelected: (v) => update(() {
                      v ? responderIds.add(r.id) : responderIds.remove(r.id);
                    }))]),
                  if (field.hasError) Text(field.errorText!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ])),
              OutlinedButton.icon(icon: const Icon(Icons.calendar_today), label: Text('대응일: ${Fmt.date(completedAt)}'),
                onPressed: () async {
                  final date = await pickDate(ctx, completedAt, firstDate: DateTime(1900), lastDate: DateTime(2100, 12, 31));
                  if (date != null && ctx.mounted) update(() => completedAt = date);
                }),
            ],
            TextFormField(controller: noteController, decoration: const InputDecoration(labelText: '변경 메모')),
            const SizedBox(height: 10),
            TextFormField(controller: minutesController, decoration: const InputDecoration(labelText: '작업 시간 (분)'), keyboardType: TextInputType.number),
          ]))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
          FilledButton(onPressed: () { if (form.currentState!.validate()) Navigator.of(ctx).pop(true); }, child: const Text('저장')),
        ],
      )),
    );
    final confirmed = await Navigator.of(context, rootNavigator: true).push(dialog);
    await dialog.completed;
    final note = noteController.text.trim();
    final resultNote = resultController.text.trim();
    final minutes = int.tryParse(minutesController.text);
    noteController.dispose();
    resultController.dispose();
    minutesController.dispose();
    if (confirmed != true || !mounted) return;
    final ok = await runGuarded(context, () async {
      final saved = await context.read<ServiceRepository>().changeStatus(ticket.id, next,
        note: note.isEmpty ? null : note, resultNote: requiresResult ? resultNote : null,
        responderIds: requiresResult ? responderIds.toList() : null,
        completedAt: requiresResult ? completedAt : null, workMinutes: minutes);
      if (!mounted) return;
      AppSnack.show(context, saved.notices.isEmpty
        ? (requiresResult ? '종결 처리되었습니다.' : '상태가 변경되었습니다.') : saved.notices.join('\n'));
    });
    if (ok && mounted) { _changed = true; reload(); }
  }

  static int _daysLeft(DateTime due) {
    final now = DateTime.now();
    return DateTime.utc(due.year, due.month, due.day).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  }

  static String _ddayLabel(DateTime due) {
    final days = _daysLeft(due);
    return days == 0 ? 'D-day' : days > 0 ? 'D-$days' : 'D+${-days}';
  }

  Future<void> _addLog(String ticketId, VoidCallback reload) async {
    final controller = TextEditingController();
    final minutes = TextEditingController();
    final dialog = DialogRoute<bool>(
      context: context,
      builder: (ctx) => ConfirmDialog.form(
        title: const Text('작업 기록 추가'),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: '내용 *'),
              maxLines: 3,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: minutes,
              decoration: const InputDecoration(labelText: '작업 시간 (분)'),
              keyboardType: TextInputType.number,
            ),
          ],
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    final confirmed = await Navigator.of(context, rootNavigator: true).push(dialog);
    await dialog.completed;
    final content = controller.text.trim();
    final workMinutes = int.tryParse(minutes.text);
    controller.dispose();
    minutes.dispose();
    if (confirmed != true || content.isEmpty || !mounted) return;

    final ok = await runGuarded(
      context,
      () => context.read<ServiceRepository>().addLog(
            ticketId,
            content,
            workMinutes: workMinutes,
          ),
      successMessage: '기록이 추가되었습니다.',
    );
    if (ok && mounted) {
      _changed = true;
      reload();
    }
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(title: title, child: Column(children: [
      for (final (label, value) in rows) Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 78, child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant))),
          Expanded(child: Text(value)),
        ]),
      ),
    ]));
  }
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => SectionCard(title: title, child: SelectableText(body));
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.log});
  final ServiceLog log;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4, right: 10),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: log.toStatus?.color ?? scheme.outline,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.content ?? '-',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  '${log.author?.fullName ?? '작성자 미상'} · ${Fmt.dateTime(log.createdAt)}'
                  '${log.workMinutes != null ? ' · ${Fmt.duration(log.workMinutes)}' : ''}',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
