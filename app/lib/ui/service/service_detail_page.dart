import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/service_repository.dart';
import '../../models/service.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';

class ServiceDetailPage extends StatefulWidget {
  const ServiceDetailPage({super.key, required this.ticketId});
  final String ticketId;

  @override
  State<ServiceDetailPage> createState() => _ServiceDetailPageState();
}

class _ServiceDetailPageState extends State<ServiceDetailPage> {
  final _viewKey = GlobalKey<AsyncViewState<ServiceTicket>>();
  bool _changed = false;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ServiceRepository>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('AS 상세')),
        body: AsyncView<ServiceTicket>(
          key: _viewKey,
          load: () => repo.get(widget.ticketId),
          builder: (context, t, reload) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
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
                t.ticketNo,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 16),

              _InfoCard(
                title: '접수 정보',
                rows: [
                  ('거래처', t.customerLabel),
                  ('연락처', t.contactPhone ?? '-'),
                  ('현장 주소', t.siteAddress ?? '-'),
                  ('접수 경로', t.channel.label),
                  ('접수 일시', Fmt.dateTime(t.receivedAt)),
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
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('사용 부품',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
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
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('처리 이력',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      if (t.logs.isEmpty)
                        const Text('기록이 없습니다.',
                            style: TextStyle(fontSize: 12))
                      else
                        for (final log in t.logs) _LogRow(log: log),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final next in t.status.nextOptions)
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
          ),
        ),
      ),
    );
  }

  Future<void> _changeStatus(
    ServiceTicket ticket,
    ServiceStatus next,
    VoidCallback reload,
  ) async {
    final noteController = TextEditingController();
    final resultController = TextEditingController(text: ticket.resultNote);
    final minutesController = TextEditingController();

    // Completing requires a result note unless an admin turned that rule off,
    // so the dialog asks for it up front rather than letting the API reject.
    final requiresResult = next == ServiceStatus.completed;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${next.label}(으)로 변경'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (requiresResult)
                TextField(
                  controller: resultController,
                  decoration: const InputDecoration(
                    labelText: '처리 내용 *',
                    helperText: '완료 처리에는 처리 내용이 필요합니다.',
                  ),
                  maxLines: 3,
                ),
              const SizedBox(height: 10),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(labelText: '변경 메모'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: minutesController,
                decoration: const InputDecoration(labelText: '작업 시간 (분)'),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('변경'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await runGuarded(
      context,
      () => context.read<ServiceRepository>().changeStatus(
            ticket.id,
            next,
            note: noteController.text.isEmpty ? null : noteController.text,
            resultNote:
                requiresResult && resultController.text.isNotEmpty
                    ? resultController.text
                    : null,
            workMinutes: int.tryParse(minutesController.text),
          ),
      successMessage: '${next.label}(으)로 변경되었습니다.',
    );
    if (ok) {
      _changed = true;
      reload();
    }
  }

  Future<void> _addLog(String ticketId, VoidCallback reload) async {
    final controller = TextEditingController();
    final minutes = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('작업 기록 추가'),
        content: Column(
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
        ),
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
    if (confirmed != true || controller.text.trim().isEmpty || !mounted) return;

    final ok = await runGuarded(
      context,
      () => context.read<ServiceRepository>().addLog(
            ticketId,
            controller.text.trim(),
            workMinutes: int.tryParse(minutes.text),
          ),
      successMessage: '기록이 추가되었습니다.',
    );
    if (ok) {
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 78,
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                    Expanded(
                      child: Text(value, style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SelectableText(body, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
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
                  '${Fmt.dateTime(log.createdAt)}'
                  '${log.workMinutes != null ? ' · ${Fmt.duration(log.workMinutes)}' : ''}',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
