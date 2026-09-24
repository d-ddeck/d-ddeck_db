import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../data/service_repository.dart';
import '../../models/common.dart';
import '../../models/service.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';
import 'service_detail_page.dart';
import 'service_form_page.dart';
import 'service_stats_page.dart';

/// 서비스(AS) module: ticket list on one tab, automatic statistics on the other.
class ServicePage extends StatefulWidget {
  const ServicePage({super.key});

  @override
  State<ServicePage> createState() => _ServicePageState();
}

class _ServicePageState extends State<ServicePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '접수 목록', icon: Icon(Icons.list_alt, size: 18)),
            Tab(text: '자동 통계', icon: Icon(Icons.insights, size: 18)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: const [ServiceListTab(), ServiceStatsTab()],
          ),
        ),
      ],
    );
  }
}

class ServiceListTab extends StatefulWidget {
  const ServiceListTab({super.key});

  @override
  State<ServiceListTab> createState() => _ServiceListTabState();
}

class _ServiceListTabState extends State<ServiceListTab> {
  final _searchController = TextEditingController();
  final _viewKey = GlobalKey<AsyncViewState<PagedList<ServiceTicket>>>();
  final _scroll = ScrollController();

  String? _query;
  ServiceStatus? _status;
  bool _onlyOpen = false;
  bool _mineOnly = false;

  /// 첫 쪽 뒤에 이어 붙인 것들. 한 번에 566건을 내려받으면 화면이 멎으므로
  /// 50건씩 이어 받는다. AsyncView 가 첫 쪽을 들고 있고 여기가 나머지다.
  final List<ServiceTicket> _more = [];
  int _loadedPage = 1;
  int _total = 0;
  bool _loadingMore = false;

  static const _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) _loadMore();
  }

  /// 이미 화면에 있는 건수. 첫 쪽(AsyncView 가 들고 있는 50건) + 이어 받은 것.
  int get _shownCount => _pageSize + _more.length;

  bool get _hasMore => _total == 0 || _shownCount < _total;

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await context.read<ServiceRepository>().list(
            query: _query,
            status: _status,
            onlyOpen: _onlyOpen,
            assigneeId: _mineOnly ? context.read<AuthState>().user?.id : null,
            page: _loadedPage + 1,
            size: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _loadedPage += 1;
        _more.addAll(next.items);
        _total = next.total;
        _loadingMore = false;
      });
    } catch (_) {
      // 다음 쪽을 못 받아도 이미 받은 목록은 그대로 둔다. 스크롤을 더 내리면
      // 다시 시도한다.
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 필터가 바뀌면 이어 받은 것들은 버려야 한다. 안 그러면 새 조건에
  /// 맞지 않는 옛 행이 아래에 남는다.
  void _refresh() {
    setState(() {
      _more.clear();
      _loadedPage = 1;
      _total = 0;
    });
    _viewKey.currentState?.reload();
  }

  Widget _footer(int shown, int total) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.outline);
    if (shown >= total) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: Text('전체 $total건을 모두 표시했습니다', style: style)),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: TextButton(
          onPressed: _loadMore,
          child: Text('더 보기 ($shown / $total)'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ServiceRepository>();
    final auth = context.watch<AuthState>();

    return Scaffold(
      body: Column(
        children: [
          _FilterBar(
            controller: _searchController,
            status: _status,
            onlyOpen: _onlyOpen,
            mineOnly: _mineOnly,
            onSearch: (v) => setState(() {
              _query = v.trim().isEmpty ? null : v.trim();
              _refresh();
            }),
            onStatus: (v) => setState(() {
              _status = v;
              _refresh();
            }),
            onOnlyOpen: (v) => setState(() {
              _onlyOpen = v;
              _refresh();
            }),
            onMineOnly: (v) => setState(() {
              _mineOnly = v;
              _refresh();
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncView<PagedList<ServiceTicket>>(
              key: _viewKey,
              load: () => repo.list(
                query: _query,
                status: _status,
                onlyOpen: _onlyOpen,
                assigneeId: _mineOnly ? auth.user?.id : null,
                size: 50,
              ),
              emptyCheck: (p) => p.isEmpty,
              emptyMessage: '조건에 맞는 접수 건이 없습니다.',
              emptyIcon: Icons.assignment_outlined,
              builder: (context, page, reload) {
                // 첫 쪽 총계를 상태로 끌어와 "더 있는지"를 판단한다.
                if (_total != page.total) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _total = page.total);
                  });
                }
                final rows = [...page.items, ..._more];
                return ListView.separated(
                  controller: _scroll,
                  itemCount: rows.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i == rows.length) return _footer(rows.length, page.total);
                    return _TicketTile(
                      ticket: rows[i],
                      onChanged: () {
                        _refresh();
                        reload();
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const ServiceFormPage()),
          );
          if (created == true) _refresh();
        },
        icon: const Icon(Icons.add),
        label: const Text('AS 접수'),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.controller,
    required this.status,
    required this.onlyOpen,
    required this.mineOnly,
    required this.onSearch,
    required this.onStatus,
    required this.onOnlyOpen,
    required this.onMineOnly,
  });

  final TextEditingController controller;
  final ServiceStatus? status;
  final bool onlyOpen;
  final bool mineOnly;
  final ValueChanged<String> onSearch;
  final ValueChanged<ServiceStatus?> onStatus;
  final ValueChanged<bool> onOnlyOpen;
  final ValueChanged<bool> onMineOnly;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        children: [
          TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: '접수번호 / 제목 / 시리얼 / 거래처 검색',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        controller.clear();
                        onSearch('');
                      },
                    ),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: onSearch,
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                FilterChip(
                  label: const Text('미완료만'),
                  selected: onlyOpen,
                  onSelected: onOnlyOpen,
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: const Text('내 담당'),
                  selected: mineOnly,
                  onSelected: onMineOnly,
                ),
                const SizedBox(width: 12),
                const VerticalDivider(width: 1),
                const SizedBox(width: 12),
                ChoiceChip(
                  label: const Text('전체'),
                  selected: status == null,
                  onSelected: (_) => onStatus(null),
                ),
                for (final s in ServiceStatus.values) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: Text(s.label),
                    selected: status == s,
                    onSelected: (_) => onStatus(s),
                    selectedColor: s.color.withValues(alpha: 0.2),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TicketTile extends StatelessWidget {
  const _TicketTile({required this.ticket, required this.onChanged});

  final ServiceTicket ticket;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: () async {
        final changed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => ServiceDetailPage(ticketId: ticket.id),
          ),
        );
        if (changed == true) onChanged();
      },
      title: Row(
        children: [
          StatusChip(
            label: ticket.status.label,
            color: ticket.status.color,
            dense: true,
          ),
          if (ticket.priority != ServicePriority.normal) ...[
            const SizedBox(width: 4),
            StatusChip(
              label: ticket.priority.label,
              color: ticket.priority.color,
              dense: true,
            ),
          ],
          if (ticket.isOverdue) ...[
            const SizedBox(width: 4),
            const StatusChip(
              label: '지연',
              color: Color(0xFFEF4444),
              icon: Icons.schedule,
              dense: true,
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ticket.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '${ticket.ticketNo} · ${ticket.customerLabel}'
          '${ticket.productName != null ? ' · ${ticket.productName}' : ''}'
          '${ticket.assignee != null ? ' · ${ticket.assignee!.fullName}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            Fmt.date(ticket.receivedAt),
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
          if (ticket.totalCost != null)
            Text(
              Fmt.money(ticket.totalCost),
              style: const TextStyle(fontSize: 11),
            ),
        ],
      ),
    );
  }
}

/// Loads a classification list from the code master.
///
/// Every dropdown in this module gets its options this way - nothing about the
/// categories is hardcoded in the client, so editing them in the admin
/// settings screen changes the forms immediately.
Future<List<CodeItem>> loadCodeItems(
  BuildContext context,
  String groupCode,
) async {
  final group = await context.read<AdminRepository>().codeGroup(groupCode);
  return group.selectable;
}
