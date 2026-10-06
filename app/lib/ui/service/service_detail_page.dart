import '../../data/inventory_repository.dart';
import '../../models/inventory.dart' show Asset;
import '../../core/api_client.dart';
import '../inventory/inventory_page.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/file_repository.dart';
import '../../models/common.dart';
import '../store/store_detail_page.dart';
import '../../data/service_repository.dart';
import '../../models/service.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../common/attachment_section.dart';
import '../format.dart';
import '../theme.dart';
import 'service_form_page.dart';
import 'ticket_history_page.dart';
import 'status_change_dialog.dart';
import 'ticket_schedule.dart';
import 'quotation_page.dart';

class ServiceDetailPage extends StatefulWidget {
  const ServiceDetailPage({super.key, required this.ticketId});
  final String ticketId;

  @override
  State<ServiceDetailPage> createState() => _ServiceDetailPageState();
}

class _ServiceDetailPageState extends State<ServiceDetailPage> {
  final _viewKey = GlobalKey<AsyncViewState<ServiceTicket>>();
  bool _changed = false;
  bool _deleting = false;

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
    final isManager = context.watch<AuthState>().isManager;
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
              tooltip: '견적서 · 수정 이력',
              icon: const Icon(Icons.request_quote_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => QuotationPage(ticketId: widget.ticketId),
                ),
              ),
            ),
            IconButton(
              tooltip: "수정 이력",
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TicketHistoryPage(ticketId: widget.ticketId),
                ),
              ),
            ),
            IconButton(
              tooltip: '내용 수정',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final t = _current;
                if (t == null) return;
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => ServiceFormPage(ticket: t)),
                );
                if (saved == true) {
                  _changed = true;
                  _viewKey.currentState?.reload();
                }
              },
            ),
            PopupMenuButton<String>(
              tooltip: '더보기',
              enabled: !_deleting,
              icon: const Icon(Icons.more_vert),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'delete',
                  enabled: isManager,
                  child: ListTile(
                    enabled: isManager,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.delete_outline,
                      color: isManager
                          ? AppColors.danger(context)
                          : Theme.of(context).disabledColor,
                    ),
                    title: Text(
                      '삭제',
                      style: TextStyle(
                        color: isManager
                            ? AppColors.danger(context)
                            : Theme.of(context).disabledColor,
                      ),
                    ),
                    subtitle: isManager
                        ? null
                        : const Text('삭제는 팀장 이상만 할 수 있습니다'),
                  ),
                ),
              ],
              onSelected: (_) => _delete(),
            ),
          ],
        ),
        body: PageBody(
          child: AsyncView<ServiceTicket>(
            key: _viewKey,
            load: () => guardedLoad(context, () => repo.get(widget.ticketId)),
            builder: (context, t, reload) => _wrap(
              t,
              Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            StatusChip(
                              label: t.status.label,
                              color: t.status.color,
                            ),
                            const SizedBox(width: 6),
                            StatusChip(
                              label: t.priority.label,
                              color: t.priority.color,
                            ),
                            const SizedBox(width: 6),
                            StatusChip(
                              label: t.isWarranty ? '보증' : '유상',
                              color: t.isWarranty
                                  ? AppColors.success(context)
                                  : AppColors.muted(context),
                            ),
                            if (t.isOverdue) ...[
                              const SizedBox(width: 6),
                              StatusChip(
                                label: '지연',
                                color: AppColors.danger(context),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          t.title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          t.displayNo,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),

                        SectionCard(
                          title: '기본 정보',
                          child: ListTile(
                            title: Text(
                              '${t.storeName ?? t.store?.name ?? '매장 미지정'} · ${t.brandName ?? t.store?.brandName ?? '-'}',
                            ),
                            subtitle: Text(
                              '${t.workTypeLabel} · 발생일 ${Fmt.date(t.receivedAt.toLocal())} · 과실 ${t.fault?.name ?? '-'}',
                            ),
                            trailing: t.storeId == null
                                ? null
                                : const Icon(Icons.chevron_right),
                            onTap: t.storeId == null
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          StoreDetailPage(storeId: t.storeId!),
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: AppSpace.md),
                        _TextCard(
                          title: '원인 · 서비스구분 · 세부분류 · 제조사',
                          body: t.causes.isEmpty
                              ? (t.causeLabels.isEmpty
                                    ? '-'
                                    : t.causeLabels.join('\n'))
                              : t.causes
                                    .map(
                                      (c) =>
                                          '${c.category?.name ?? '-'}${c.symptom == null ? '' : ' > ${c.symptom!.name}'}${c.maker == null ? '' : ' (${c.maker!.name})'}',
                                    )
                                    .join('\n'),
                        ),
                        const SizedBox(height: AppSpace.md),
                        AsyncView<List<Map<String, dynamic>>>(
                          load: () async =>
                              (await context.read<ApiClient>().get(
                                        '/service/tickets/${t.id}/assets',
                                      )
                                      as List)
                                  .map(asMap)
                                  .toList(),
                          builder: (context, assets, reload) => Wrap(
                            runSpacing: 12,
                            spacing: 8,
                            children: [
                              for (final asset in assets)
                                ActionChip(
                                  label: Text(
                                    '${asset['name']} · ${asset['serial_no'] ?? '-'}',
                                  ),
                                  avatar: const Icon(
                                    Icons.inventory_2_outlined,
                                  ),
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => AssetDetailPage(
                                        assetId: asString(asset['id']),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SectionCard(
                          title: '서비스인원',
                          child: Wrap(
                            runSpacing: 12,
                            spacing: 8,
                            children: [
                              for (final r in t.responders)
                                Chip(label: Text(r.name)),
                            ],
                          ),
                        ),
                        if (t.isRental) ...[
                          const SizedBox(height: AppSpace.md),
                          _InfoCard(
                            title: '렌탈',
                            rows: [
                              ('종류', t.rentalType?.name ?? '-'),
                              ('시리얼', t.rentalSerials ?? '-'),
                              ('회수 예정일', Fmt.date(t.rentalDueDate)),
                              ('회수 여부', t.rentalReturned ? '회수 완료' : '미회수'),
                              ('실제 회수일', Fmt.date(t.rentalReturnDate)),
                            ],
                          ),
                          if (!t.rentalReturned && t.rentalDueDate != null)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                '렌탈 미회수 · ${Fmt.dday(_daysLeft(t.rentalDueDate!))}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: _daysLeft(t.rentalDueDate!) <= 0
                                      ? AppColors.danger(context)
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                        ],
                        const SizedBox(height: 12),
                        _InfoCard(
                          title: '접수 정보',
                          rows: [
                            ('거래처', t.customerLabel),
                            ('매장 담당자', t.contactName ?? '-'),
                            ('연락처', t.contactPhone ?? '-'),
                            ('현장 주소', t.siteAddress ?? '-'),
                            ('접수 경로', t.channel.label),
                            ('접수 일시', Fmt.dateTime(t.receivedAt.toLocal())),
                            ('처리 기한', Fmt.dateTime(t.dueAt)),
                            ('담당자', t.assignee?.display ?? '미배정'),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TicketScheduleSection(ticket: t),
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

                        ...[
                          const SizedBox(height: AppSpace.md),
                          SectionCard(
                            title: '사용 부품',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextButton.icon(
                                  onPressed: () => _addPart(t, reload),
                                  icon: const Icon(Icons.add),
                                  label: const Text("부품 추가"),
                                ),
                                for (final p in t.parts)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 3,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(child: Text(p.partName)),
                                        IconButton(
                                          tooltip: '부품 삭제',
                                          icon: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          onPressed: () async {
                                            if (!await ConfirmDialog.show(
                                              context,
                                              title: '부품 삭제',
                                              message:
                                                  '사용 부품을 삭제하고 차감한 재고를 복구합니다.',
                                              confirmLabel: '삭제',
                                            )) {
                                              return;
                                            }
                                            if (!context.mounted) return;
                                            if (await runGuarded(
                                              context,
                                              () => repo.removePart(t.id, p.id),
                                            )) {
                                              _changed = true;
                                              reload();
                                            }
                                          },
                                        ),
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
                        ],

                        const SizedBox(height: AppSpace.md),
                        SectionCard(
                          title: '처리 이력',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (t.logs.isEmpty)
                                const EmptyState(message: '아직 등록된 처리 이력이 없습니다')
                              else
                                for (final log in t.logs)
                                  Column(
                                    children: [
                                      _LogRow(log: log),
                                      if (isManager ||
                                          log.author?.id ==
                                              context
                                                  .read<AuthState>()
                                                  .user
                                                  ?.id)
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            TextButton(
                                              onPressed: () =>
                                                  _editLog(t, log, reload),
                                              child: const Text('수정'),
                                            ),
                                            if (log.toStatus == null)
                                              TextButton(
                                                onPressed: () async {
                                                  if (!await ConfirmDialog.show(
                                                    context,
                                                    title: '처리 이력 삭제',
                                                    message:
                                                        '이 내용과 기록된 작업 시간을 삭제합니다.',
                                                    confirmLabel: '삭제',
                                                  )) {
                                                    return;
                                                  }
                                                  if (!context.mounted) return;
                                                  if (await runGuarded(
                                                    context,
                                                    () => repo.deleteLog(
                                                      t.id,
                                                      log.id,
                                                    ),
                                                  )) {
                                                    _changed = true;
                                                    reload();
                                                  }
                                                },
                                                child: const Text('삭제'),
                                              ),
                                          ],
                                        ),
                                    ],
                                  ),
                            ],
                          ),
                        ),

                        const SizedBox(height: AppSpace.md),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QuotationPage(ticketId: t.id),
                            ),
                          ),
                          icon: const Icon(Icons.request_quote_outlined),
                          label: const Text('견적서 작성 · PDF · 수정 이력'),
                        ),
                        const SizedBox(height: AppSpace.lg),
                        AttachmentSection(
                          entityType: FileRepository.serviceTicket,
                          entityId: t.id,
                        ),
                        const SizedBox(height: AppSpace.lg),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                  Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${t.displayNo} · ${t.status.label}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              spacing: 8,
                              children: [
                                if (t.status.isOpen)
                                  FilledButton.icon(
                                    onPressed: () => _changeStatus(
                                      t,
                                      ServiceStatus.completed,
                                      reload,
                                    ),
                                    icon: const Icon(Icons.check),
                                    label: const Text('종결 처리'),
                                  ),
                                if (t.status == ServiceStatus.completed)
                                  OutlinedButton(
                                    onPressed: () => _changeStatus(
                                      t,
                                      ServiceStatus.inProgress,
                                      reload,
                                    ),
                                    child: const Text('다시 열기'),
                                  ),
                                for (final next in t.status.nextOptions.where(
                                  (s) =>
                                      s != ServiceStatus.completed &&
                                      t.status != ServiceStatus.completed,
                                ))
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        _changeStatus(t, next, reload),
                                    icon: Icon(
                                      Icons.arrow_forward,
                                      size: 15,
                                      color: next.color,
                                    ),
                                    label: Text('${next.label}(으)로'),
                                  ),
                                OutlinedButton.icon(
                                  onPressed: () => _addLog(t.id, reload),
                                  icon: const Icon(
                                    Icons.note_add_outlined,
                                    size: 15,
                                  ),
                                  label: const Text('작업 기록 추가'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final ticket = _current;
    if (ticket == null || _deleting || !context.read<AuthState>().isManager) {
      return;
    }
    setState(() => _deleting = true);
    try {
      final confirmed = await ConfirmDialog.show(
        context,
        title: '${ticket.displayNo} 삭제',
        message: '이 기록이 목록·통계에서 사라지고 첨부·이력도 함께 숨겨집니다. 계속할까요?',
        confirmLabel: '삭제',
        destructive: true,
      );
      if (!confirmed || !mounted || !context.read<AuthState>().isManager) {
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      final deleted = await runGuarded(
        context,
        () => context.read<ServiceRepository>().delete(ticket.id),
      );
      if (!deleted || !mounted) return;
      _changed = true;
      Navigator.pop(context, true);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('삭제되었습니다'),
          duration: AppSnack.noticeDuration,
        ),
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _editLog(
    ServiceTicket ticket,
    ServiceLog log,
    VoidCallback reload,
  ) async {
    final content = TextEditingController(text: log.content),
        minutes = TextEditingController(text: '${log.workMinutes ?? 0}');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('처리 이력 수정'),
        scrollable: true,
        content: FormFields(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: content,
              maxLines: 4,
              decoration: const InputDecoration(labelText: '내용'),
            ),
            TextField(
              controller: minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '작업 시간(분)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (content.text.trim().isNotEmpty &&
                  (int.tryParse(minutes.text) ?? -1) >= 0) {
                Navigator.pop(c, true);
              }
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
    final text = content.text.trim(), amount = int.tryParse(minutes.text) ?? 0;
    // Controllers are disposed after the dialog route's closing animation.
    Future<void>.delayed(const Duration(seconds: 1), () {
      content.dispose();
      minutes.dispose();
    });
    if (accepted != true || !mounted) return;
    if (await runGuarded(
      context,
      () => context.read<ServiceRepository>().updateLog(
        ticket.id,
        log.id,
        text,
        amount,
      ),
    )) {
      _changed = true;
      reload();
    }
  }

  Future<void> _addPart(ServiceTicket ticket, VoidCallback reload) async {
    String? assetId;
    final inventory = context.read<InventoryRepository>();
    final name = TextEditingController(),
        quantity = TextEditingController(text: '1'),
        price = TextEditingController(text: '0');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('사용 부품 추가'),
        scrollable: true,
        content: FormFields(
          mainAxisSize: MainAxisSize.min,
          children: [
            Autocomplete<Asset>(
              displayStringForOption: (asset) =>
                  '${asset.name} · ${asset.serialNo ?? asset.assetNo}',
              optionsBuilder: (value) async => value.text.trim().isEmpty
                  ? <Asset>[]
                  : (await inventory.list(
                      query: value.text.trim(),
                      size: 20,
                    )).items,
              fieldViewBuilder: (c, controller, focus, submit) => TextField(
                controller: controller,
                focusNode: focus,
                decoration: const InputDecoration(labelText: '연결할 재고 검색 (선택)'),
              ),
              onSelected: (asset) {
                assetId = asset.id;
                name.text = asset.name;
              },
            ),
            const Text('재고를 연결하면 서버의 부품 자동 차감 설정이 적용됩니다.'),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '부품명'),
            ),
            TextField(
              controller: quantity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '수량'),
            ),
            TextField(
              controller: price,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '단가'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty &&
                  (double.tryParse(quantity.text) ?? 0) > 0 &&
                  (double.tryParse(price.text) ?? -1) >= 0) {
                Navigator.pop(c, true);
              }
            },
            child: const Text('추가'),
          ),
        ],
      ),
    );
    final text = name.text.trim(),
        count = double.tryParse(quantity.text) ?? 1,
        cost = double.tryParse(price.text) ?? 0;
    Future<void>.delayed(const Duration(seconds: 1), () {
      name.dispose();
      quantity.dispose();
      price.dispose();
    });
    if (accepted != true || !mounted) return;
    if (await runGuarded(
      context,
      () => context.read<ServiceRepository>().addPart(
        ticket.id,
        text,
        count,
        cost,
        assetId: assetId,
      ),
    )) {
      _changed = true;
      reload();
    }
  }

  Future<void> _changeStatus(
    ServiceTicket ticket,
    ServiceStatus next,
    VoidCallback reload,
  ) async {
    final input = await askStatusChange(context, ticket, next);
    if (input == null || !mounted) return;
    final saved = await applyStatusChange(context, ticket.id, next, input);
    if (saved != null && mounted) {
      _changed = true;
      reload();
    }
  }

  static int _daysLeft(DateTime due) {
    final now = DateTime.now();
    return DateTime.utc(
      due.year,
      due.month,
      due.day,
    ).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  }

  Future<void> _addLog(String ticketId, VoidCallback reload) async {
    final controller = TextEditingController();
    final minutes = TextEditingController();
    final dialog = DialogRoute<bool>(
      context: context,
      builder: (ctx) => ConfirmDialog.form(
        title: const Text('작업 기록 추가'),
        content: SingleChildScrollView(
          padding: fieldLabelInsets(ctx),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: '내용 *'),
                maxLines: 3,
              ),
              const FormGap(),
              TextField(
                controller: minutes,
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
            child: const Text('저장'),
          ),
        ],
      ),
    );
    final confirmed = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(dialog);
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
    return SectionCard(
      title: title,
      child: Column(
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(
                      label,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Expanded(child: Text(value)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) =>
      SectionCard(title: title, child: SelectableText(body));
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
                Text(log.content ?? '-', style: const TextStyle(fontSize: 13)),
                Text(
                  '${log.author?.fullName ?? '작성자 미상'} · ${Fmt.dateTime(log.createdAt)}'
                  '${log.workMinutes != null ? ' · ${Fmt.duration(log.workMinutes)}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
