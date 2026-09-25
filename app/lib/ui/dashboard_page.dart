import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/calendar_repository.dart';
import '../data/inventory_repository.dart';
import '../data/service_repository.dart';
import '../models/calendar.dart';
import '../models/common.dart';
import '../models/inventory.dart';
import '../models/service.dart';
import '../state/auth_state.dart';
import 'async_view.dart';
import 'format.dart';
import 'theme.dart';
import 'service/service_detail_page.dart';
import 'service/service_page.dart';
import 'service/service_feedback.dart';

/// Everything the dashboard shows, fetched in one round of parallel calls.
class _DashboardData {
  const _DashboardData({
    required this.summary,
    required this.myOpen,
    required this.inventory,
    required this.todayEvents,
    required this.service,
  });

  final ServiceDashboard service;
  final ServiceSummary summary;
  final PagedList<ServiceTicket> myOpen;
  final InventorySummary inventory;
  final List<CalendarEvent> todayEvents;
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final serviceRepo = context.read<ServiceRepository>();
    final inventoryRepo = context.read<InventoryRepository>();
    final calendarRepo = context.read<CalendarRepository>();

    return AsyncView<_DashboardData>(
      load: () => serviceLoad(context, () async {
        final now = DateTime.now();
        final monthStart = DateTime(now.year, now.month, 1);
        final dayStart = DateTime(now.year, now.month, now.day);

        // 독립적인 대시보드 조회를 함께 요청한다.
        final results = await Future.wait([
          serviceRepo.summary(dateFrom: monthStart),
          serviceRepo.list(
            onlyOpen: true,
            assigneeId: auth.user?.id,
            size: 5,
          ),
          inventoryRepo.summary(),
          calendarRepo.events(
            from: dayStart,
            to: dayStart.add(const Duration(days: 1)),
          ),
          serviceRepo.dashboard(limit: 10),
        ]);
        return _DashboardData(
          summary: results[0] as ServiceSummary,
          myOpen: results[1] as PagedList<ServiceTicket>,
          inventory: results[2] as InventorySummary,
          todayEvents: results[3] as List<CalendarEvent>,
          service: results[4] as ServiceDashboard,
        );
      }),
      builder: (context, data, reload) {
        final wide = AppTheme.isWide(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '${auth.user?.fullName ?? ''}님, 안녕하세요',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              '${Fmt.date(DateTime.now())} · 이번 달 기준',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
            const SizedBox(height: 16),

            GridView.count(
              crossAxisCount: wide ? 4 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: wide ? 1.9 : 1.55,
              children: [
                StatTile(
                  label: 'AS 접수 (당월)',
                  value: '${data.summary.total}건',
                  hint: '완료 ${data.summary.completedCount}건',
                  icon: Icons.assignment_outlined,
                ),
                StatTile(
                  label: '완료율',
                  value: Fmt.percent(data.summary.completionRate, digits: 0),
                  hint: '평균 ${Fmt.duration(data.summary.avgResolutionMinutes)}',
                  icon: Icons.check_circle_outline,
                  color: const Color(0xFF10B981),
                ),
                StatTile(
                  label: '처리 지연',
                  value: '${data.summary.overdueCount}건',
                  hint: '미완료 ${data.summary.openCount}건',
                  icon: Icons.schedule,
                  color: data.summary.overdueCount > 0
                      ? const Color(0xFFEF4444)
                      : null,
                ),
                StatTile(
                  label: '보유 자산',
                  value: '${data.inventory.totalAssets}건',
                  hint: data.inventory.belowMinCount > 0
                      ? '안전재고 미만 ${data.inventory.belowMinCount}건'
                      : Fmt.money(data.inventory.totalValue),
                  icon: Icons.inventory_2_outlined,
                  color: data.inventory.belowMinCount > 0
                      ? const Color(0xFFF59E0B)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 20),

            _Section(title: '미종결 ${data.service.openCount}건', child: Column(children: [
              if (data.service.openTickets.isEmpty) const _EmptyRow(text: '미종결 기록이 없습니다.'),
              for (final t in data.service.openTickets.take(10)) ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${t.ticketNo} · ${t.storeName ?? '-'}'),
                subtitle: Text('${Fmt.date(t.receivedAt.toLocal())} · ${t.daysOpen ?? 0}일 경과'),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceDetailPage(ticketId: t.id)));
                  if (context.mounted) reload();
                },
              ),
              TextButton(onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServiceListTab(initialOnlyOpen: true)));
                if (context.mounted) reload();
              }, child: const Text('전체 보기')),
            ])),
            const SizedBox(height: 16),
            _Section(title: '렌탈 미회수', child: Column(children: [
              if (data.service.unreturnedRentals.isEmpty) const _EmptyRow(text: '미회수 렌탈이 없습니다.'),
              for (final r in data.service.unreturnedRentals) ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${r.ticketNo} · ${r.storeName ?? '-'}'),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${r.rentalType ?? '-'} · ${r.serials ?? '-'}'),
                  Text('회수 예정 ${Fmt.date(r.dueDate)} · ${r.dday == null ? '-' : r.dday == 0 ? 'D-day' : r.dday! > 0 ? 'D-${r.dday}' : 'D+${-r.dday!}'}',
                    style: TextStyle(color: r.dday != null && r.dday! <= 0 ? Colors.red : null, fontWeight: FontWeight.w700)),
                ]),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServiceDetailPage(ticketId: r.ticketId)));
                  if (context.mounted) reload();
                },
              ),
            ])),
            const SizedBox(height: 16),
            _Section(title: '최근 기록', child: Column(children: [
              if (data.service.recent.isEmpty) const _EmptyRow(text: '최근 기록이 없습니다.'),
              for (final t in data.service.recent.take(10)) _TicketRow(ticket: t, onChanged: reload),
            ])),
            const SizedBox(height: 16),
            _Section(title: '연도별 건수', child: Column(children: [
              if (data.service.byYear.isEmpty) const _EmptyRow(text: '집계된 기록이 없습니다.'),
              for (final y in data.service.byYear) Padding(
                padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
                  SizedBox(width: 52, child: Text(y.year)),
                  Expanded(child: LinearProgressIndicator(minHeight: 12, value:
                    y.count / data.service.byYear.fold<int>(1, (max, row) => row.count > max ? row.count : max))),
                  SizedBox(width: 70, child: Text('${y.count}건', textAlign: TextAlign.right)),
                ])),
            ])),
            const SizedBox(height: 16),

            _Section(
              title: '내 진행중 AS',
              trailing: '${data.myOpen.total}건',
              child: data.myOpen.isEmpty
                  ? const _EmptyRow(text: '진행중인 AS가 없습니다.')
                  : Column(
                      children: [
                        for (final t in data.myOpen.items)
                          _TicketRow(ticket: t, onChanged: reload),
                      ],
                    ),
            ),
            const SizedBox(height: 16),

            _Section(
              title: '오늘 일정',
              trailing: '${data.todayEvents.length}건',
              child: data.todayEvents.isEmpty
                  ? const _EmptyRow(text: '오늘 등록된 일정이 없습니다.')
                  : Column(
                      children: [
                        for (final e in data.todayEvents) _EventRow(event: e),
                      ],
                    ),
            ),
            const SizedBox(height: 16),

            if (data.summary.byStatus.isNotEmpty)
              _Section(
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
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ),
      );
}

class _TicketRow extends StatelessWidget {
  const _TicketRow({required this.ticket, this.onChanged});
  final VoidCallback? onChanged;
  final ServiceTicket ticket;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () async {
        final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ServiceDetailPage(ticketId: ticket.id)));
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
          ? const StatusChip(
              label: '지연', color: Color(0xFFEF4444), dense: true)
          : Text(
              Fmt.relative(ticket.receivedAt),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    return ListTile(
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
              '${bucket.count}건 ${Fmt.percent(bucket.ratio, digits: 0)}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
