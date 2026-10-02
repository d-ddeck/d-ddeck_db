import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/calendar_repository.dart';
import '../../models/calendar.dart';
import '../../models/service.dart';
import '../async_view.dart';
import '../calendar/event_detail_sheet.dart';
import '../calendar/event_form_page.dart';
import '../common/common.dart';
import '../format.dart';
import '../theme.dart';

/// 서비스 대응 건 내용으로 일정 등록 화면을 채워 연다. 등록하면 그 일정을 돌려준다.
Future<CalendarEvent?> registerTicketSchedule(
  BuildContext context,
  ServiceTicket t,
) async {
  final store = t.storeName ?? t.store?.name;
  final now = DateTime.now();
  final due = t.dueAt?.toLocal();
  CalendarEvent? saved;
  await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => EventFormPage(
        initialDate: due != null && due.isAfter(now) ? due : now,
        initialTitle: '[AS] ${store ?? t.customerLabel} · ${t.workTypeLabel}',
        initialLocation: t.siteAddress ?? store,
        initialDescription: [
          t.displayNo,
          if (t.description?.trim().isNotEmpty == true) t.description!.trim(),
        ].join('\n'),
        initialParticipants: [?t.assignee],
        serviceTicketId: t.id,
        onSaved: (event) => saved = event,
      ),
    ),
  );
  return saved;
}

/// AS 상세의 '연결 일정' 카드: 이 건에서 등록한 일정 목록과 등록 버튼.
class TicketScheduleSection extends StatefulWidget {
  const TicketScheduleSection({super.key, required this.ticket});
  final ServiceTicket ticket;

  @override
  State<TicketScheduleSection> createState() => _TicketScheduleSectionState();
}

class _TicketScheduleSectionState extends State<TicketScheduleSection> {
  final _viewKey = GlobalKey<AsyncViewState<List<CalendarEvent>>>();

  void _reload() => _viewKey.currentState?.reload();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<CalendarRepository>();
    return SectionCard(
      title: '연결 일정',
      actions: [
        TextButton.icon(
          onPressed: () async {
            final saved = await registerTicketSchedule(context, widget.ticket);
            if (saved != null) _reload();
          },
          icon: const Icon(Icons.event_available_outlined),
          label: const Text('일정 등록'),
        ),
      ],
      child: AsyncView<List<CalendarEvent>>(
        key: _viewKey,
        load: () => repo.ticketEvents(widget.ticket.id),
        builder: (context, events, reload) => events.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
                child: Text('캘린더에 등록된 일정이 없습니다'),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final e in events)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        e.status == EventStatus.canceled
                            ? Icons.event_busy_outlined
                            : Icons.event_outlined,
                        color: e.status == EventStatus.canceled
                            ? Theme.of(context).disabledColor
                            : e.displayColor(
                                Theme.of(context).colorScheme.primary,
                              ),
                      ),
                      title: Text(e.title),
                      subtitle: Text(
                        Fmt.range(e.startsAt, e.endsAt, allDay: e.allDay),
                      ),
                      trailing: e.status == EventStatus.scheduled
                          ? null
                          : Text(e.status.label),
                      onTap: () async {
                        CalendarEvent? full;
                        if (!await runGuarded(
                              context,
                              () async => full = await repo.event(e.id),
                            ) ||
                            !context.mounted) {
                          return;
                        }
                        // 수정·삭제 여부와 상관없이 시트가 닫히면 목록을 새로 읽는다.
                        await EventDetailSheet.show(context, full!);
                        reload();
                      },
                    ),
                ],
              ),
      ),
    );
  }
}
