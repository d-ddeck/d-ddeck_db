import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/api_client.dart';
import '../../models/common.dart';
import '../../models/service.dart';
import '../async_view.dart';
import '../common/common.dart';
import '../service/service_detail_page.dart';

class AssetTicketsSection extends StatefulWidget {
  const AssetTicketsSection({super.key, required this.assetId});
  final String assetId;
  @override
  State<AssetTicketsSection> createState() => _AssetTicketsSectionState();
}

class _AssetTicketsSectionState extends State<AssetTicketsSection> {
  int _page = 1;
  @override
  Widget build(BuildContext context) => SectionCard(
    title: '관련 대응 기록',
    child: AsyncView<PagedList<ServiceTicket>>(
      key: ValueKey(_page),
      load: () async => PagedList.fromJson(
        await context.read<ApiClient>().get(
          '/inventory/assets/${widget.assetId}/tickets',
          query: {'page': _page, 'size': 20},
        ),
        ServiceTicket.fromJson,
      ),
      builder: (context, data, reload) => Column(
        children: [
          for (final ticket in data.items)
            ListTile(
              title: Text('${ticket.displayNo} · ${ticket.title}'),
              subtitle: Text(ticket.status.label),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ServiceDetailPage(ticketId: ticket.id),
                ),
              ),
            ),
          if (data.items.isEmpty) const Text('관련 기록이 없습니다.'),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: _page > 1 ? () => setState(() => _page--) : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('$_page / ${data.pages}'),
              IconButton(
                onPressed: data.hasMore ? () => setState(() => _page++) : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
