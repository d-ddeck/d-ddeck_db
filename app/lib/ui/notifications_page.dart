import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/calendar_repository.dart';
import '../models/common.dart';
import '../models/user.dart';
import '../state/auth_state.dart';
import 'async_view.dart';
import 'format.dart';

/// In-app notification inbox.
///
/// The server creates these rows for invitations, reminders, AS assignments,
/// board comments and account approvals. Push mirroring is not live on the
/// backend yet, so this list plus the badge poll is the delivery path.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final _viewKey = GlobalKey<AsyncViewState<PagedList<AppNotification>>>();
  bool _unreadOnly = false;

  void _refresh() {
    _viewKey.currentState?.reload();
    context.read<AuthState>().refreshUnread();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<CalendarRepository>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('알림'),
        actions: [
          IconButton(
            tooltip: '모두 읽음',
            icon: const Icon(Icons.done_all),
            onPressed: () async {
              final ok = await runGuarded(
                context,
                repo.markAllRead,
                successMessage: '모두 읽음 처리했습니다.',
              );
              if (ok) _refresh();
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('읽지 않음만'),
                  selected: _unreadOnly,
                  onSelected: (v) => setState(() {
                    _unreadOnly = v;
                    _viewKey.currentState?.reload();
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
      body: AsyncView<PagedList<AppNotification>>(
        key: _viewKey,
        load: () => repo.notifications(unreadOnly: _unreadOnly, size: 50),
        emptyCheck: (p) => p.isEmpty,
        emptyMessage: '알림이 없습니다.',
        emptyIcon: Icons.notifications_none,
        builder: (context, page, reload) => ListView.separated(
          itemCount: page.items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final n = page.items[i];
            return ListTile(
              leading: Icon(
                _iconFor(n.type),
                color: n.isRead
                    ? Theme.of(context).colorScheme.outline
                    : Theme.of(context).colorScheme.primary,
              ),
              title: Text(
                n.title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: n.isRead ? FontWeight.w400 : FontWeight.w700,
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (n.body != null)
                    Text(n.body!, style: const TextStyle(fontSize: 12)),
                  Text(
                    Fmt.relative(n.createdAt),
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
              trailing: n.isRead
                  ? null
                  : Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
              onTap: () async {
                if (!n.isRead) {
                  await runGuarded(context, () => repo.markRead(n.id));
                  if (!context.mounted) return;
                  _refresh();
                }
                // The payload carries a deep-link route. Wiring it to a router
                // is the next step; for now the destination is shown so the
                // contract is visible to whoever picks this up.
                if (n.route != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('이동 대상: ${n.route}')),
                  );
                }
              },
            );
          },
        ),
      ),
    );
  }

  static IconData _iconFor(String type) => switch (type) {
        'EVENT_REMINDER' => Icons.alarm,
        'EVENT_INVITED' => Icons.event_available,
        'EVENT_UPDATED' => Icons.edit_calendar,
        'EVENT_CANCELED' => Icons.event_busy,
        'SERVICE_ASSIGNED' => Icons.build,
        'BOARD_COMMENT' => Icons.comment,
        'ACCOUNT_APPROVED' => Icons.verified_user,
        'ACCOUNT_REJECTED' => Icons.person_off,
        _ => Icons.notifications,
      };
}
