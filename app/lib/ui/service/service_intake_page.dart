import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../data/admin_repository.dart';
import '../../data/calendar_repository.dart';
import '../../models/calendar.dart';
import '../../models/common.dart';
import '../../models/service.dart';
import '../async_view.dart';
import '../calendar/event_form_page.dart';
import '../common/common.dart';
import '../format.dart';
import '../theme.dart';
import 'quotation_page.dart';

/// 접수 폼(1단계)에서 넘겨받는, 아직 저장하지 않은 접수 내용.
class ServiceIntakeDraft {
  const ServiceIntakeDraft({
    required this.title,
    required this.responders,
    required this.save,
    this.storeId,
    this.storeName,
    this.customerName,
    this.contactName,
    this.contactPhone,
    this.siteAddress,
    this.description,
    this.workTypeLabel,
    this.assignee,
  });

  final String title;
  final String? storeId, storeName, customerName, contactName, contactPhone;
  final String? siteAddress, description, workTypeLabel;
  final UserBrief? assignee;

  /// 접수 폼과 같은 집합. 종결 단계에서 고친 서비스인원이 그대로 저장된다.
  final Set<String> responders;

  /// 접수 건을 [status] 로 저장한다. 실패하면 ApiException 을 던진다.
  final Future<ServiceTicket> Function(
    ServiceStatus status, {
    String? resultNote,
    DateTime? completedAt,
  })
  save;
}

/// 신규 접수의 2·3단계. 견적서와 일정은 임시로만 들고 있다가, 마지막에
/// 진행중/종결을 골라 완료하면 접수 건을 저장하고 그 건에 이어서 등록한다.
/// 저장되면 그 건을, 이전 단계(접수 폼)로 돌아가면 null 을 돌려준다.
class ServiceIntakeFlowPage extends StatefulWidget {
  const ServiceIntakeFlowPage({super.key, required this.draft});
  final ServiceIntakeDraft draft;

  static const steps = ['내용 접수', '견적서 작성', '일정 · 처리 상태'];

  @override
  State<ServiceIntakeFlowPage> createState() => _ServiceIntakeFlowPageState();
}

class _ServiceIntakeFlowPageState extends State<ServiceIntakeFlowPage> {
  final _form = GlobalKey<FormState>();
  final _resultNote = TextEditingController();

  /// 0 은 접수 폼이라 1(견적서)부터 시작한다.
  int _step = 1;
  Map<String, dynamic>? _quotation;
  final List<EventDraft> _events = [];
  ServiceStatus _status = ServiceStatus.inProgress;
  DateTime _completedAt = DateTime.now();
  bool _busy = false;
  bool _done = false;

  ServiceIntakeDraft get _draft => widget.draft;

  @override
  void dispose() {
    _resultNote.dispose();
    super.dispose();
  }

  Future<void> _editQuotation() async {
    var initial = _quotation;
    if (initial == null) {
      final ok = await runGuarded(context, () async {
        initial = asMap(
          await context.read<ApiClient>().get(
            '/service/quotations/defaults',
            query: {
              'store_id': _draft.storeId,
              'customer_name': _draft.customerName,
              'contact_name': _draft.contactName,
              'contact_phone': _draft.contactPhone,
              'site_address': _draft.siteAddress,
            },
          ),
        );
      });
      if (!ok || !mounted) return;
    }
    final checklist = await loadQuoteChecklist(context.read<ApiClient>());
    if (!mounted) return;
    final body = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) =>
            QuotationEditPage.draft(initial: initial!, checklist: checklist),
      ),
    );
    if (body != null && mounted) setState(() => _quotation = body);
  }

  Future<void> _addEvent() async {
    final store = _draft.storeName;
    final now = DateTime.now();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EventFormPage(
          initialDate: now,
          initialTitle:
              '[AS] ${store ?? _draft.customerName ?? _draft.title} · ${_draft.workTypeLabel ?? '미분류'}',
          initialLocation: _draft.siteAddress ?? store,
          initialDescription: _draft.description,
          initialParticipants: [?_draft.assignee],
          onDraft: (event) => setState(() => _events.add(event)),
        ),
      ),
    );
  }

  Future<void> _finish() async {
    final completing = _status == ServiceStatus.completed;
    if (completing && !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    ServiceTicket? saved;
    final ok = await runGuarded(context, () async {
      saved = await _draft.save(
        _status,
        resultNote: completing ? _resultNote.text.trim() : null,
        completedAt: completing ? _completedAt : null,
      );
    });
    if (!mounted) return;
    if (!ok || saved == null) {
      setState(() => _busy = false);
      return;
    }
    final ticket = saved!;
    // 접수는 저장됐다. 남은 등록이 실패해도 접수는 되돌리지 않고 알려만 준다.
    final failed = <String>[];
    final quotation = _quotation;
    if (quotation != null) {
      try {
        await context.read<ApiClient>().post(
          '/service/tickets/${ticket.id}/quotations',
          body: quotation,
        );
      } catch (_) {
        failed.add('견적서');
      }
    }
    if (!mounted) return;
    final calendar = context.read<CalendarRepository>();
    var eventFailures = 0;
    for (final event in _events) {
      try {
        await calendar.createDraft(event, serviceTicketId: ticket.id);
      } catch (_) {
        eventFailures++;
      }
    }
    if (eventFailures > 0) failed.add('일정 $eventFailures건');
    if (!mounted) return;
    if (failed.isNotEmpty) {
      AppSnack.show(
        context,
        '접수는 저장되었지만 ${failed.join(', ')} 등록에 실패했습니다. AS 상세에서 다시 등록해 주세요.',
        error: true,
      );
    }
    setState(() {
      _busy = false;
      _done = true;
    });
    Navigator.of(context).pop(ticket);
  }

  Future<void> _back() async {
    if (_busy) return;
    if (_step > 1) {
      setState(() => _step--);
      return;
    }
    final hasDrafts = _quotation != null || _events.isNotEmpty;
    if (hasDrafts &&
        !await ConfirmDialog.show(
          context,
          title: '내용 접수로 돌아가기',
          message: '작성한 견적서와 일정은 아직 저장되지 않아 사라집니다.',
          confirmLabel: '돌아가기',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _done = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _done,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('서비스 기록 접수')),
        body: PageBody(
          child: Form(
            key: _form,
            child: Column(
              children: [
                _StepHeader(current: _step),
                const SizedBox(height: AppSpace.md),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.edit_note),
                          title: Text(_draft.title),
                          subtitle: Text(
                            '${_draft.storeName ?? _draft.customerName ?? '매장 미지정'} · 저장 전',
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      if (_step == 1)
                        _quotationStep()
                      else ...[
                        _scheduleCard(),
                        const SizedBox(height: AppSpace.md),
                        _statusCard(),
                      ],
                    ],
                  ),
                ),
                FormActions(
                  child: Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : _back,
                          child: Text(_step == 1 ? '이전 (내용 수정)' : '이전'),
                        ),
                      ),
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy
                              ? null
                              : _step == 1
                              ? () => setState(() => _step = 2)
                              : _finish,
                          child: Text(
                            _busy
                                ? '저장 중…'
                                : _step == 1
                                ? (_quotation == null ? '건너뛰기' : '다음')
                                : _status == ServiceStatus.completed
                                ? '종결로 접수 저장'
                                : '진행중으로 접수 저장',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quotationStep() {
    final quotation = _quotation;
    final items = (quotation?['items'] as List? ?? [])
        .map(asMap)
        .where((i) => asString(i['name']).isNotEmpty)
        .toList();
    final total = items.fold<double>(
      0,
      (sum, i) =>
          sum +
          (double.tryParse(asString(i['quantity'])) ?? 0) *
              (double.tryParse(asString(i['unit_price'])) ?? 0),
    );
    return SectionCard(
      title: '견적서',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            quotation == null
                ? '작성된 견적서가 없습니다. 필요 없으면 건너뛰세요.'
                : '품목 ${items.length}개 · 공급가 ${Fmt.money(total)} '
                      '(접수 저장 시 함께 등록)',
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _editQuotation,
                  icon: const Icon(Icons.request_quote_outlined),
                  label: Text(quotation == null ? '견적서 작성' : '견적서 수정'),
                ),
              ),
              if (quotation != null)
                IconButton(
                  tooltip: '견적서 삭제',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _busy
                      ? null
                      : () => setState(() => _quotation = null),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scheduleCard() => SectionCard(
    title: '일정 등록',
    actions: [
      TextButton.icon(
        onPressed: _busy ? null : _addEvent,
        icon: const Icon(Icons.event_available_outlined),
        label: const Text('일정 추가'),
      ),
    ],
    child: _events.isEmpty
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
            child: Text('추가한 일정이 없습니다. 필요 없으면 건너뛰세요.'),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, e) in _events.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: Text(e.title),
                  subtitle: Text(
                    Fmt.range(e.startsAt, e.endsAt, allDay: e.allDay),
                  ),
                  trailing: IconButton(
                    tooltip: '일정 빼기',
                    icon: const Icon(Icons.close),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _events.removeAt(i)),
                  ),
                ),
            ],
          ),
  );

  Widget _statusCard() => SectionCard(
    title: '처리 상태',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<ServiceStatus>(
          segments: const [
            ButtonSegment(
              value: ServiceStatus.inProgress,
              label: Text('진행중'),
              icon: Icon(Icons.autorenew),
            ),
            ButtonSegment(
              value: ServiceStatus.completed,
              label: Text('종결'),
              icon: Icon(Icons.check),
            ),
          ],
          selected: {_status},
          onSelectionChanged: _busy
              ? null
              : (v) => setState(() => _status = v.first),
        ),
        if (_status == ServiceStatus.completed) ...[
          const FormGap(),
          TextFormField(
            controller: _resultNote,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '서비스 내용 *'),
            validator: (v) =>
                v == null || v.trim().isEmpty ? '서비스 내용을 입력해 주세요.' : null,
          ),
          const FormGap(),
          _ResponderField(selected: _draft.responders, enabled: !_busy),
          const FormGap(),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today),
              label: Text('서비스일: ${Fmt.date(_completedAt)}'),
              onPressed: _busy
                  ? null
                  : () async {
                      final date = await pickDate(
                        context,
                        _completedAt,
                        firstDate: DateTime(1900),
                        lastDate: DateTime(2100, 12, 31),
                      );
                      if (date != null && mounted) {
                        setState(() => _completedAt = date);
                      }
                    },
            ),
          ),
        ] else ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            '처리가 남은 건은 진행중으로 저장하고 AS 상세에서 종결하세요.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

/// 종결에 필요한 서비스인원. 접수 폼에서 고른 값으로 시작한다.
class _ResponderField extends StatelessWidget {
  const _ResponderField({required this.selected, required this.enabled});
  final Set<String> selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => AsyncView<List<CodeItem>>(
    load: () async => (await context.read<AdminRepository>().codeGroup(
      'SERVICE_RESPONDER',
      includeHistorical: true,
    )).items,
    builder: (context, responders, _) => FormField<bool>(
      validator: (_) => selected.isEmpty ? '서비스인원을 선택해 주세요.' : null,
      builder: (field) => StatefulBuilder(
        builder: (context, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('서비스인원 *'),
            const FormGap(),
            Wrap(
              spacing: 8,
              runSpacing: AppSpace.md,
              children: [
                for (final r in responders)
                  if (r.isActive || selected.contains(r.id))
                    FilterChip(
                      label: Text(r.name),
                      selected: selected.contains(r.id),
                      onSelected: enabled
                          ? (v) => update(() {
                              v ? selected.add(r.id) : selected.remove(r.id);
                              field.didChange(v);
                            })
                          : null,
                    ),
              ],
            ),
            if (field.hasError)
              Text(
                field.errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
  );
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.current});
  final int current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final (i, label) in ServiceIntakeFlowPage.steps.indexed) ...[
          if (i > 0)
            Expanded(
              child: Divider(
                indent: 4,
                endIndent: 4,
                color: i <= current ? scheme.primary : scheme.outlineVariant,
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: i <= current
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                foregroundColor: i <= current
                    ? scheme.onPrimary
                    : scheme.onSurfaceVariant,
                child: i < current
                    ? const Icon(Icons.check, size: 16)
                    : Text('${i + 1}', style: const TextStyle(fontSize: 12)),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: i == current ? FontWeight.w700 : null,
                  color: i <= current ? null : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
