import '../common/history_cleanup_button.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/api_client.dart';
import '../../models/common.dart';
import '../async_view.dart';
import '../common/common.dart';
import '../format.dart';

class TicketHistoryPage extends StatefulWidget {
  const TicketHistoryPage({super.key, required this.ticketId});
  final String ticketId;
  @override
  State<TicketHistoryPage> createState() => _TicketHistoryPageState();
}

class _TicketHistoryPageState extends State<TicketHistoryPage> {
  int _page = 1;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('수정 이력')),
    body: PageBody(
      child: AsyncView<Map<String, dynamic>>(
        key: ValueKey(_page),
        load: () async => asMap(
          await context.read<ApiClient>().get(
            '/service/tickets/${widget.ticketId}/history',
            query: {'page': _page, 'size': 30},
          ),
        ),
        builder: (context, data, reload) {
          final rows = data['items'] as List? ?? [];
          return ListView(
            children: [
              for (final value in rows)
                Builder(
                  builder: (context) {
                    final row = asMap(value),
                        changes = asMap(asMap(value)['changes']);
                    return ExpansionTile(
                      title: Text(asString(row['summary'], '변경')),
                      subtitle: Text(
                        '${Fmt.dateTime(asDate(row['created_at']))} · ${row['actor_email'] ?? '-'}',
                      ),
                      children: [
                        HistoryCleanupButton(
                          kind: "audit",
                          id: asString(row["id"]),
                          onChanged: reload,
                        ),
                        for (final change in changes.entries)
                          ListTile(
                            title: Text(change.key),
                            subtitle: SelectableText('${change.value}'),
                          ),
                      ],
                    );
                  },
                ),
              if (rows.isEmpty) const EmptyState(message: '수정 이력이 없습니다'),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _page > 1 ? () => setState(() => _page--) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('$_page / ${data['pages'] ?? 1}'),
                  IconButton(
                    onPressed: _page * 30 < asInt(data['total'])
                        ? () => setState(() => _page++)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ),
  );
}
