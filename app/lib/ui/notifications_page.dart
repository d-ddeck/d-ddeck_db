import '../data/board_repository.dart';
import 'board/board_page.dart';
import 'calendar/event_detail_sheet.dart';
import 'service/service_detail_page.dart';
import 'admin/admin_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'common/common.dart';

import '../data/calendar_repository.dart';
import '../models/common.dart';
import '../models/user.dart';
import '../state/auth_state.dart';
import 'async_view.dart';
import 'format.dart';

/// In-app notification inbox.
///
/// The server creates these rows for invitations, reminders, AS assignments,
/// board comments and account approvals. The inbox remains available when
/// optional Firebase push delivery is not configured.
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
      ),
      body: PageBody(
        child: Column(
          children: [
            FilterBar(
              appliedFilters: [if (_unreadOnly) '읽지 않음만'],
              onReset: () {
                setState(() => _unreadOnly = false);
                _refresh();
              },
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
            Expanded(
              child: AsyncView<PagedList<AppNotification>>(
                key: _viewKey,
                load: () =>
                    repo.notifications(unreadOnly: _unreadOnly, size: 50),
                emptyCheck: (p) => p.isEmpty,
                emptyMessage: '아직 등록된 알림이 없습니다',
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
                          fontWeight: n.isRead
                              ? FontWeight.w400
                              : FontWeight.w700,
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
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
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
                        if (context.mounted) {
                          await runGuarded(context, () => _open(context, n));
                        }
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, AppNotification notification) async {
    final payload = notification.payload ?? {};
    Widget? page;
    switch (notification.route) {
      case '/service/ticket':
        final id = payload['ticket_id'];
        if (id is String) page = ServiceDetailPage(ticketId: id);
      case '/board/post':
        final id = payload['post_id'];
        if (id is! String) break;
        final repository = context.read<BoardRepository>();
        final post = await repository.post(id);
        final boards = await repository.boards();
        final board = boards.where((b) => b.id == post.boardId).firstOrNull;
        if (board != null) page = PostDetailPage(postId: id, board: board);
      case '/calendar/event':
        final id = payload['event_id'];
        if (id is! String) break;
        final event = await context.read<CalendarRepository>().event(id);
        if (context.mounted) await EventDetailSheet.show(context, event);
        return;
      case '/admin/users/pending':
        if (context.read<AuthState>().isAdmin) page = const AdminPage();
    }
    if (!context.mounted) return;
    if (page != null) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => page!),
      );
    } else {
      AppSnack.show(context, '이 알림은 이동할 수 있는 화면이 없습니다.');
    }
  }

  static const _icons = <String, IconData>{
    'EVENT_REMINDER': Icons.alarm,
    'EVENT_INVITED': Icons.event_available,
    'EVENT_UPDATED': Icons.edit_calendar,
    'EVENT_CANCELED': Icons.event_busy,
    'SERVICE_ASSIGNED': Icons.build,
    'BOARD_COMMENT': Icons.comment,
    'ACCOUNT_APPROVED': Icons.verified_user,
    'ACCOUNT_REJECTED': Icons.person_off,
  };
  static IconData _iconFor(String type) => _icons[type] ?? Icons.notifications;
}
