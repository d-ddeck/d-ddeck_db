import '../common/section_main_reporter.dart';
import '../../core/api_exception.dart';
import '../../state/auth_state.dart';
import '../../services/filter_memory.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/admin_repository.dart';
import '../../data/service_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/service.dart';
import '../../models/store.dart';
import '../common/download.dart';
import '../format.dart';
import '../theme.dart';
import 'service_detail_page.dart';
import 'service_form_page.dart';
import 'service_stats_page.dart';
import 'service_ticket_row.dart';

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
    return SectionMainReporter(
      controller: _tabs,
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            tabs: const [
              WorkspaceTab(text: '접수 목록', icon: Icon(Icons.list_alt, size: 18)),
              WorkspaceTab(text: '자동 통계', icon: Icon(Icons.insights, size: 18)),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [ServiceListTab(), ServiceStatsTab()],
            ),
          ),
        ],
      ),
    );
  }
}

class ServiceListTab extends StatefulWidget {
  const ServiceListTab({
    super.key,
    this.initialOnlyOpen = false,
    this.initialFilters = const {},
  });
  final bool initialOnlyOpen;
  final Map<String, dynamic> initialFilters;

  @override
  State<ServiceListTab> createState() => _ServiceListTabState();
}

class _ServiceListTabState extends State<ServiceListTab> {
  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, dynamic> _filters = {};
  final Map<String, List<CodeItem>> _codes = {};
  List<BrandSummary> _brands = [];
  List<Store> _stores = [];
  final List<ServiceTicket> _rows = [];
  ServiceSummary? _summary;
  List<int>? _searchCounts;
  int _overallTotal = 0;
  int _page = 0, _total = 0, _generation = 0, _storeRequest = 0;
  bool _loading = false, _loadingMore = false, _exporting = false;
  bool _failed = false;
  String? _filterMemoryKey;
  String _sort = 'received_desc';

  @override
  void initState() {
    super.initState();
    _filters.addAll(widget.initialFilters);
    if (widget.initialOnlyOpen) _filters['only_open'] = true;
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final auth = context.read<AuthState>();
      final owner = auth.user?.id;
      if (owner != null) {
        _filterMemoryKey = FilterMemory.key(auth.serverUrl, owner, 'service');
        if (widget.initialFilters.isEmpty && !widget.initialOnlyOpen) {
          final saved = await FilterMemory.load(_filterMemoryKey!);
          if (!mounted) return;
          _sort = saved.remove('_sort') as String? ?? _sort;
          _filters.addAll(saved);
          _searchController.text = _filters['q'] as String? ?? '';
        }
      }
      _loadLookups();
      _refresh();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadLookups() async {
    final request = ++_storeRequest;
    final brand = _filters['brand_id'] as String?;
    final admin = context.read<AdminRepository>();
    final stores = context.read<StoreRepository>();
    await runGuarded(context, () async {
      final results = await Future.wait<dynamic>([
        stores.brands(),
        stores.all(brandId: brand, includeClosed: true),
        for (final g in [
          'SERVICE_WORK_TYPE',
          'SERVICE_CATEGORY',
          'SERVICE_SYMPTOM',
          'SERVICE_FAULT',
          'SERVICE_RESPONDER',
        ])
          admin.codeGroup(g),
      ]);
      if (!mounted) return;
      setState(() {
        _brands = results[0] as List<BrandSummary>;
        if (request == _storeRequest) {
          _stores = results[1] as List<Store>;
        }
        for (final group in results.skip(2).cast<CodeGroup>()) {
          _codes[group.code] = group.items;
        }
      });
    });
  }

  Map<String, dynamic> get _summaryFilters =>
      Map<String, dynamic>.from(_filters)
        ..remove('status')
        ..remove('only_open')
        ..remove('q');

  Future<void> _refresh() async {
    if (!mounted) return;
    if (_filterMemoryKey != null) {
      FilterMemory.save(_filterMemoryKey!, {..._filters, "_sort": _sort});
    }
    final generation = ++_generation;
    final repo = context.read<ServiceRepository>();
    final filters = Map<String, dynamic>.from(_filters);
    final summaryFilters = _summaryFilters;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _failed = false;
    });
    final ok = await runGuarded(context, () async {
      final results =
          await Future.wait<dynamic>([
            repo.list(filters: filters, sort: _sort, size: 50),
            repo.summary(filters: summaryFilters),
            repo.list(size: 1),
            // summary 계약에는 q가 없다. 검색어가 있을 때 같은 목록 조건의 총건수를 쓴다.
            if (filters['q'] != null) ...[
              for (final state in [null, 'COMPLETED', 'open'])
                repo.list(
                  size: 1,
                  filters: {
                    ...summaryFilters,
                    'q': filters['q'],
                    if (state == 'COMPLETED') 'status': state,
                    if (state == 'open') 'only_open': true,
                  },
                ),
            ],
          ]).catchError((Object error) {
            if (error is ApiException &&
                [401, 403, 404].contains(error.statusCode) &&
                mounted &&
                generation == _generation) {
              setState(_rows.clear);
            }
            throw error;
          });
      if (!mounted || generation != _generation) return;
      final page = results[0] as PagedList<ServiceTicket>;
      setState(() {
        _rows
          ..clear()
          ..addAll(page.items);
        _searchCounts = null;
        _total = page.total;
        _page = 1;
        _summary = results[1] as ServiceSummary;
        _overallTotal = (results[2] as PagedList<ServiceTicket>).total;
        if (results.length > 3) {
          _searchCounts = results
              .skip(3)
              .cast<PagedList<ServiceTicket>>()
              .map((p) => p.total)
              .toList();
        }
      });
    });
    if (mounted && generation == _generation) {
      setState(() {
        _loading = false;
        _failed = !ok;
      });
    }
  }

  void _onScroll() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _page == 0 || _rows.length >= _total) {
      return;
    }
    final generation = _generation;
    setState(() => _loadingMore = true);
    await runGuarded(context, () async {
      final page = await context.read<ServiceRepository>().list(
        page: _page + 1,
        size: 50,
        filters: Map<String, dynamic>.from(_filters),
        sort: _sort,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _rows.addAll(page.items);
        _page = page.page;
        _total = page.total;
      });
    });
    if (mounted && generation == _generation) {
      setState(() => _loadingMore = false);
    }
  }

  void _set(String key, dynamic value) {
    if (value == null || value == '') {
      _filters.remove(key);
    } else {
      _filters[key] = value;
    }
  }

  String _filterLabel(String key, dynamic value) {
    if (key == 'year') return '$value년';
    if (key == 'month') return '$value월';
    if (key == 'q') return '검색: $value';
    if (key == 'only_open') return '미종결';
    if (key == 'status') return ServiceStatus.parse(value.toString()).label;
    if (key == 'is_rental') return '렌탈만';
    if (key == 'rental_unreturned') return '렌탈 미회수';
    if (key == 'missing' && value == 'work_type') return '업무 구분 미분류';
    if (key == 'brand_id') {
      return _brands.where((b) => b.brandId == value).firstOrNull?.brandName ??
          '브랜드';
    }
    if (key == 'store_id') {
      return _stores.where((s) => s.id == value).firstOrNull?.name ?? '매장';
    }
    return _codes.values
            .expand((c) => c)
            .where((c) => c.id == value)
            .firstOrNull
            ?.name ??
        value.toString();
  }

  void _removeFilter(int index) {
    final key = _filters.keys.elementAt(index);
    _filters.remove(key);
    if (key == 'q') _searchController.clear();
    if (key == 'year') _filters.remove('month');
    if (key == 'brand_id') _filters.remove('store_id');
    if (key == 'category_id') _filters.remove('symptom_id');
    if (key == 'is_rental') _filters.remove('rental_unreturned');
    if (key == 'brand_id') _loadLookups();
    _refresh();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    await runGuarded(context, () async {
      final bytes = await context.read<ServiceRepository>().exportXlsx(
        filters: Map<String, dynamic>.from(_filters),
      );
      await saveAndOpenDownload(
        bytes,
        '서비스기록_${ServiceRepository.dateOnly(DateTime.now())}.xlsx',
      );
    });
    if (mounted) setState(() => _exporting = false);
  }

  Future<void> _create() async {
    final created = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ServiceFormPage()));
    if (created == true && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('서비스 기록'),
      actions: [
        TextButton.icon(
          onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.download),
          label: Text(_exporting ? '저장 중' : '엑셀'),
        ),
        const SizedBox(width: AppSpace.lg),
      ],
    ),
    floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    floatingActionButton: FloatingActionButton.extended(
      heroTag: 'create-service',
      tooltip: '접수',
      onPressed: _create,
      icon: const Icon(Icons.edit_outlined),
      label: const Text('+'),
    ),
    body: PageBody.workspace(
      child: Column(
        children: [
          FilterBar(
            onRemoveFilter: _removeFilter,
            appliedFilters: [
              for (final e in _filters.entries) _filterLabel(e.key, e.value),
            ],
            onReset: () {
              _filters.clear();
              _searchController.clear();
              _sort = 'received_desc';
              _loadLookups();
              _refresh();
            },
            children: [
              SizedBox(
                width: AppTheme.isWide(context) ? 360 : double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '번호 / 내용 / 매장 / 인원 / 시리얼 검색',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.search),
                        onPressed: () {
                          _set('q', _searchController.text.trim());
                          _refresh();
                        },
                      ),
                    ),
                    onSubmitted: (v) {
                      _set('q', v.trim());
                      _refresh();
                    },
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final entry in [
                      (0, '전체', _searchCounts?[0] ?? _summary?.total),
                      (1, '종결', _searchCounts?[1] ?? _summary?.completedCount),
                      (2, '미종결', _searchCounts?[2] ?? _summary?.openCount),
                    ])
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: ActionChip(
                          label: Text(
                            '${entry.$2} ${entry.$3 == null ? '…' : Fmt.number(entry.$3)}',
                          ),
                          onPressed: () {
                            _set('status', entry.$1 == 1 ? 'COMPLETED' : null);
                            _set('only_open', entry.$1 == 2 ? true : null);
                            _refresh();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '검색 ${Fmt.number(_total)}건 / 전체 ${Fmt.number(_overallTotal)}건 · 표시 ${Fmt.number(_rows.length)}건',
            ),
          ),
          if (_loading && _rows.isNotEmpty)
            const LinearProgressIndicator(semanticsLabel: '이전 자료를 표시하며 검색 중'),
          if (_failed && _rows.isNotEmpty)
            TextButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('갱신 실패 · 이전 자료입니다. 다시 시도'),
            ),
          const ServiceTicketRow.header(),
          Expanded(
            child: _loading && _rows.isEmpty
                ? const LoadingState()
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.builder(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: _rows.length + 1,
                      itemBuilder: (context, i) {
                        if (i == _rows.length) {
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Center(
                              child: _failed
                                  ? ErrorState(
                                      message: '서비스 기록을 불러오지 못했습니다',
                                      onRetry: _refresh,
                                    )
                                  : _loadingMore
                                  ? const LoadingState()
                                  : _rows.length < _total
                                  ? TextButton(
                                      onPressed: _loadMore,
                                      child: Text(
                                        '더 보기 (${_rows.length} / $_total)',
                                      ),
                                    )
                                  : _total == 0
                                  ? EmptyState(
                                      message: _filters.isEmpty
                                          ? '아직 등록된 서비스 기록이 없습니다'
                                          : '검색 조건에 맞는 서비스 기록이 없습니다',
                                      action: OutlinedButton(
                                        onPressed: _filters.isEmpty
                                            ? _create
                                            : () {
                                                _filters.clear();
                                                _searchController.clear();
                                                _sort = 'received_desc';
                                                _loadLookups();
                                                _refresh();
                                              },
                                        child: Text(
                                          _filters.isEmpty
                                              ? '접수하기'
                                              : '검색 조건 초기화',
                                        ),
                                      ),
                                    )
                                  : Text('전체 ${Fmt.number(_total)}건'),
                            ),
                          );
                        }
                        return Padding(
                          padding: EdgeInsets.only(
                            top: i == 0 ? 0 : AppSpace.sm,
                          ),
                          child: _TicketTile(
                            ticket: _rows[i],
                            onChanged: _refresh,
                          ),
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

class _TicketTile extends StatelessWidget {
  const _TicketTile({required this.ticket, required this.onChanged});
  final ServiceTicket ticket;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => ServiceTicketRow(
    ticket: ticket,
    onTap: () async {
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ServiceDetailPage(ticketId: ticket.id),
        ),
      );
      if (changed == true) onChanged();
    },
  );
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
