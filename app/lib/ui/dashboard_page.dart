import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/board_repository.dart';
import '../data/calendar_repository.dart';
import '../data/service_repository.dart';
import '../models/board.dart';
import '../models/calendar.dart';
import '../models/common.dart';
import '../models/service.dart';
import '../state/auth_state.dart';
import 'async_view.dart';
import 'format.dart';
import 'common/common.dart';
import 'board/board_page.dart';
import 'calendar/calendar_page.dart';
import 'calendar/event_detail_sheet.dart';
import 'theme.dart';
import 'service/service_detail_page.dart';
import 'service/service_page.dart';

/// Everything the dashboard shows, fetched in one round of parallel calls.
class _DashboardData {
  const _DashboardData({
    required this.summary,
    required this.mine,
    required this.mineThisMonth,
    required this.myOpen,
    required this.todayEvents,
    required this.service,
    required this.noticeBoard,
    required this.notices,
  });

  final ServiceDashboard service;
  final Board? noticeBoard;
  final List<Post> notices;
  final ServiceSummary summary;

  /// 나에게 배정된(담당자) 서비스: 전체 기간 / 당월 접수분.
  final ServiceSummary mine;
  final ServiceSummary mineThisMonth;
  final PagedList<ServiceTicket> myOpen;
  final List<CalendarEvent> todayEvents;
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final serviceRepo = context.read<ServiceRepository>();
    final calendarRepo = context.read<CalendarRepository>();
    final boardRepo = context.read<BoardRepository>();

    // 공지가 없거나 볼 권한이 없어도 대시보드는 그대로 연다.
    Future<(Board?, List<Post>)> latestNotices() async {
      try {
        final boards = await boardRepo.boards();
        final notice = boards
            .where((b) => b.type == BoardType.notice)
            .firstOrNull;
        if (notice == null) return (null, <Post>[]);
        return (notice, (await boardRepo.posts(notice.id, size: 5)).items);
      } catch (_) {
        return (null, <Post>[]);
      }
    }

    return AsyncView<_DashboardData>(
      load: () => guardedLoad(context, () async {
        final now = DateTime.now();
        final monthStart = DateTime(now.year, now.month, 1);
        final dayStart = DateTime(now.year, now.month, now.day);

        // 독립적인 대시보드 조회를 함께 요청한다.
        final results = await Future.wait([
          serviceRepo.summary(filter: ServiceFilter(dateFrom: monthStart)),
          serviceRepo.list(onlyOpen: true, assigneeId: auth.user?.id, size: 5),
          calendarRepo.events(
            from: dayStart,
            to: dayStart.add(const Duration(days: 1)),
          ),
          serviceRepo.dashboard(limit: 5),
          serviceRepo.summary(filter: ServiceFilter(assigneeId: auth.user?.id)),
          latestNotices(),
          serviceRepo.summary(
            filter: ServiceFilter(
              assigneeId: auth.user?.id,
              dateFrom: monthStart,
            ),
          ),
        ]);
        final notices = results[5] as (Board?, List<Post>);
        return _DashboardData(
          summary: results[0] as ServiceSummary,
          mine: results[4] as ServiceSummary,
          mineThisMonth: results[6] as ServiceSummary,
          myOpen: results[1] as PagedList<ServiceTicket>,
          todayEvents: results[2] as List<CalendarEvent>,
          service: results[3] as ServiceDashboard,
          noticeBoard: notices.$1,
          notices: notices.$2,
        );
      }),
      builder: (context, data, reload) {
        Future<void> viewAll(Widget page) async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('전체 보기')),
                body: page,
              ),
            ),
          );
          if (context.mounted) reload();
        }

        return ListView(
          children: [
            PageBody.workspace(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${auth.user?.fullName ?? ''}님, 안녕하세요',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${Fmt.date(DateTime.now())} · 나에게 배정된 서비스 현황',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  SectionCard(
                    title: '공지사항',
                    actions: [
                      TextButton(
                        onPressed: () => viewAll(const BoardPage()),
                        child: const Text('전체 보기'),
                      ),
                    ],
                    child: Column(
                      children: [
                        if (data.notices.isEmpty)
                          const _EmptyRow(text: '등록된 공지사항이 없습니다'),
                        for (final post in data.notices)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              post.isPinned
                                  ? Icons.push_pin_outlined
                                  : Icons.campaign_outlined,
                            ),
                            title: Text(
                              post.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(Fmt.date(post.createdAt)),
                            onTap: () => viewAll(
                              PostDetailPage(
                                postId: post.id,
                                board: data.noticeBoard!,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      final textScale =
                          MediaQuery.textScalerOf(context).scale(14) / 14;
                      final tileWidth =
                          ((constraints.maxWidth - 3 * AppSpace.md) / 4).clamp(
                            180 * textScale,
                            double.infinity,
                          );
                      final tiles = <Widget>[
                        StatTile(
                          label: '배정 서비스',
                          onTap: () => viewAll(
                            ServiceListTab(
                              initialFilters: {'assignee_id': auth.user?.id},
                            ),
                          ),
                          value: '${Fmt.number(data.mine.total)}건',
                          hint: '나에게 배정 · 전체 기간',
                          icon: Icons.assignment_ind_outlined,
                        ),
                        StatTile(
                          label: '미처리',
                          onTap: () => viewAll(
                            ServiceListTab(
                              initialOnlyOpen: true,
                              initialFilters: {'assignee_id': auth.user?.id},
                            ),
                          ),
                          value: '${Fmt.number(data.mine.openCount)}건',
                          hint: '배정 건 중 미종결',
                          icon: Icons.pending_actions,
                          color: data.mine.openCount > 0
                              ? AppColors.warning(context)
                              : null,
                        ),
                        StatTile(
                          label: '당월 배정 접수',
                          onTap: () {
                            final now = DateTime.now();
                            viewAll(
                              ServiceListTab(
                                initialFilters: {
                                  'assignee_id': auth.user?.id,
                                  // 칸 숫자와 같은 조건: 이번 달 1일부터 접수.
                                  'date_from': Fmt.date(
                                    DateTime(now.year, now.month, 1),
                                  ),
                                },
                              ),
                            );
                          },
                          value: '${Fmt.number(data.mineThisMonth.total)}건',
                          hint:
                              '종결 ${Fmt.number(data.mineThisMonth.total - data.mineThisMonth.openCount)}건',
                          icon: Icons.assignment_outlined,
                        ),
                        StatTile(
                          label: '종결률',
                          // 배정 건 기준: (배정 - 미처리) / 배정
                          value: Fmt.percent(
                            data.mine.completionRate,
                            digits: 0,
                          ),
                          hint: '배정 건 기준',
                          icon: Icons.check_circle_outline,
                          color: AppColors.success(context),
                        ),
                      ];
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < tiles.length; i++) ...[
                              if (i > 0) const SizedBox(width: AppSpace.md),
                              SizedBox(
                                width: tileWidth,
                                height: 132 * textScale,
                                child: tiles[i],
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: AppSpace.md),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      // Reserve three standard two-line ticket rows in each panel.
                      final panelBodyHeight =
                          216 * MediaQuery.textScalerOf(context).scale(14) / 14;
                      Widget panelBody(Widget child) => SizedBox(
                        height: panelBodyHeight,
                        child: SingleChildScrollView(child: child),
                      );
                      final panels = <Widget>[
                        SectionCard(
                          title:
                              '오늘 일정 · ${Fmt.number(data.todayEvents.length)}건',
                          actions: [
                            TextButton(
                              onPressed: () => viewAll(const CalendarPage()),
                              child: const Text('전체 보기'),
                            ),
                          ],
                          child: panelBody(
                            data.todayEvents.isEmpty
                                ? const _EmptyRow(text: '아직 등록된 오늘 일정이 없습니다')
                                : Column(
                                    children: [
                                      for (final e in data.todayEvents.take(3))
                                        _EventRow(
                                          event: e,
                                          onChanged: () {
                                            if (context.mounted) reload();
                                          },
                                        ),
                                    ],
                                  ),
                          ),
                        ),

                        SectionCard(
                          title: '미종결 ${Fmt.number(data.service.openCount)}건',
                          actions: [
                            TextButton(
                              onPressed: () => viewAll(
                                const ServiceListTab(initialOnlyOpen: true),
                              ),
                              child: const Text('전체 보기'),
                            ),
                          ],
                          child: panelBody(
                            Column(
                              children: [
                                if (data.service.openTickets.isEmpty)
                                  const _EmptyRow(text: '아직 등록된 미종결 기록이 없습니다'),
                                for (final t in data.service.openTickets.take(
                                  3,
                                ))
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      '${t.ticketNo} · ${t.storeName ?? '-'}',
                                    ),
                                    subtitle: Text(
                                      '${Fmt.date(t.receivedAt.toLocal())} · ${t.daysOpen ?? 0}일 경과',
                                    ),
                                    onTap: () async {
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              ServiceDetailPage(ticketId: t.id),
                                        ),
                                      );
                                      if (context.mounted) reload();
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ),

                        SectionCard(
                          title: '렌탈 미회수',
                          actions: [
                            TextButton(
                              onPressed: () => viewAll(
                                const ServiceListTab(
                                  initialFilters: {
                                    'is_rental': true,
                                    'rental_unreturned': true,
                                  },
                                ),
                              ),
                              child: const Text('전체 보기'),
                            ),
                          ],
                          child: panelBody(
                            Column(
                              children: [
                                if (data.service.unreturnedRentals.isEmpty)
                                  const _EmptyRow(text: '아직 등록된 미회수 렌탈이 없습니다'),
                                for (final r
                                    in data.service.unreturnedRentals.take(3))
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      '${r.ticketNo} · ${r.storeName ?? '-'}',
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${r.rentalType ?? '-'} · ${r.serials ?? '-'}',
                                        ),
                                        Text(
                                          '회수 예정 ${Fmt.date(r.dueDate)} · ${Fmt.dday(r.dday)}',
                                          style: TextStyle(
                                            color:
                                                r.dday != null && r.dday! <= 0
                                                ? AppColors.danger(context)
                                                : null,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                    onTap: () async {
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ServiceDetailPage(
                                            ticketId: r.ticketId,
                                          ),
                                        ),
                                      );
                                      if (context.mounted) reload();
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ];
                      if (constraints.maxWidth >= 1100 &&
                          MediaQuery.textScalerOf(context).scale(14) < 20) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < panels.length; i++) ...[
                              if (i > 0) const SizedBox(width: AppSpace.md),
                              Expanded(child: panels[i]),
                            ],
                          ],
                        );
                      }
                      // 칸 사이에만 간격을 둬 다른 칸과 같은 간격이 되게 한다.
                      return Column(
                        children: [
                          for (var i = 0; i < panels.length; i++) ...[
                            if (i > 0) const SizedBox(height: AppSpace.md),
                            panels[i],
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: AppSpace.md),
                  SectionCard(
                    title: '최근 기록',
                    actions: [
                      TextButton(
                        onPressed: () => viewAll(const ServiceListTab()),
                        child: const Text('전체 보기'),
                      ),
                    ],
                    child: Column(
                      children: [
                        if (data.service.recent.isEmpty)
                          const _EmptyRow(text: '아직 등록된 서비스 기록이 없습니다'),
                        for (final t in data.service.recent.take(3))
                          _TicketRow(ticket: t, onChanged: reload),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  SectionCard(
                    title: '내 진행중 AS · ${Fmt.number(data.myOpen.total)}건',
                    child: data.myOpen.isEmpty
                        ? const _EmptyRow(text: '아직 등록된 진행 중 AS가 없습니다')
                        : Column(
                            children: [
                              for (final t in data.myOpen.items)
                                _TicketRow(ticket: t, onChanged: reload),
                            ],
                          ),
                  ),
                  if (data.summary.byStatus.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.md),
                    SectionCard(
                      title: 'AS 상태 분포 (당월)',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            for (final b in data.summary.byStatus)
                              _BucketBar(bucket: b),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpace.md),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => EmptyState(message: text);
}

class _TicketRow extends StatelessWidget {
  const _TicketRow({required this.ticket, this.onChanged});
  final VoidCallback? onChanged;
  final ServiceTicket ticket;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () async {
        final changed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => ServiceDetailPage(ticketId: ticket.id),
          ),
        );
        if (changed == true) onChanged?.call();
      },
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: StatusChip(
        label: ticket.status.label,
        color: ticket.status.color,
        dense: true,
      ),
      title: Text(
        ticket.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        '${ticket.displayNo} · ${ticket.storeName ?? ticket.customerLabel}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: ticket.isOverdue
          ? StatusChip(
              label: '지연',
              color: AppColors.danger(context),
              dense: true,
            )
          : Text(
              Fmt.relative(ticket.receivedAt),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.onChanged});
  final CalendarEvent event;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => EventDetailSheet.show(context, event, onChanged: onChanged),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 4,
        height: 32,
        decoration: BoxDecoration(
          color: event.displayColor(event.calendar?.displayColor),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      title: Text(
        event.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        event.allDay
            ? '종일'
            : '${Fmt.time(event.startsAt)} ~ ${Fmt.time(event.endsAt)}'
                  '${event.location != null ? ' · ${event.location}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}

/// Horizontal share bar. Colour comes from the server so it matches the chips
/// and the statistics charts without a client-side palette.
class _BucketBar extends StatelessWidget {
  const _BucketBar({required this.bucket});
  final StatBucket bucket;

  @override
  Widget build(BuildContext context) {
    final color = bucket.color != null
        ? parseHexColor(bucket.color!)
        : Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              bucket.label,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: bucket.ratio.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: color.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          SizedBox(
            width: 62,
            child: Text(
              '${Fmt.number(bucket.count)}건 ${Fmt.percent(bucket.ratio, digits: 0)}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
