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
  bool _failed = false, _lookupsReady = false, _storesLoading = false;
  String? _filterMemoryKey;
  String _sort = 'received_desc';
  static const _sortLabels = {
    'brand_asc': '브랜드↑',
    'brand_desc': '브랜드↓',
    'ticket_no_asc': '번호↑',
    'ticket_no_desc': '번호↓',
    'store_asc': '매장↑',
    'store_desc': '매장↓',
    'status_asc': '상태↑',
    'status_desc': '상태↓',
    'completed_asc': '대응일↑',
    'completed_desc': '대응일↓',
    'received_desc': '발생일↓',
    'received_asc': '발생일↑',
    'created_desc': '등록순',
    'updated_desc': '수정순',
  };

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
          _storesLoading = false;
        }
        for (final group in results.skip(2).cast<CodeGroup>()) {
          _codes[group.code] = group.items;
        }
        _lookupsReady = true;
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

  Widget _select(
    String label,
    String key,
    Map<String, String> choices,
    StateSetter update, {
    bool enabled = true,
    void Function(String?)? after,
  }) => SizedBox(
    width: AppTheme.isWide(context) ? 180 : double.infinity,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$key:${_filters[key]}:${choices.keys.join(',')}'),
      initialValue: choices.containsKey(_filters[key]?.toString())
          ? _filters[key].toString()
          : '',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: '', child: Text('전체')),
        for (final c in choices.entries)
          DropdownMenuItem(value: c.key, child: Text(c.value)),
      ],
      onChanged: enabled
          ? (v) {
              update(() => _set(key, v));
              after?.call(v == '' ? null : v);
            }
          : null,
    ),
  );

  Map<String, String> _codeChoices(String group, {String? parent}) => {
    for (final c in _codes[group] ?? <CodeItem>[])
      if (parent == null || c.parentId == parent) c.id: c.name,
  };

  Future<void> _editFilters() async {
    if (!_lookupsReady) await _loadLookups();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, update) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.viewInsetsOf(ctx).bottom + 16,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.72,
              child: Column(
                children: [
                  const Text(
                    '검색 조건',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: fieldLabelInsets(ctx),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _select(
                            '연도',
                            'year',
                            {
                              for (var y = DateTime.now().year; y >= 2000; y--)
                                '$y': '$y년',
                            },
                            update,
                            after: (v) {
                              if (v == null) {
                                update(() => _filters.remove('month'));
                              }
                            },
                          ),
                          _select(
                            '월',
                            'month',
                            {for (var m = 1; m <= 12; m++) '$m': '$m월'},
                            update,
                            enabled: _filters['year'] != null,
                          ),
                          _select(
                            '브랜드',
                            'brand_id',
                            {
                              for (final b in _brands)
                                if (b.brandId != null) b.brandId!: b.brandName,
                            },
                            update,
                            after: (brand) async {
                              final request = ++_storeRequest;
                              update(() {
                                _filters.remove('store_id');
                                _stores = [];
                                _storesLoading = true;
                              });
                              await runGuarded(context, () async {
                                final page = await context
                                    .read<StoreRepository>()
                                    .all(brandId: brand, includeClosed: true);
                                if (mounted && request == _storeRequest) {
                                  if (ctx.mounted) {
                                    update(() => _stores = page);
                                  } else {
                                    _stores = page;
                                  }
                                }
                              });
                              if (mounted && request == _storeRequest) {
                                if (ctx.mounted) {
                                  update(() => _storesLoading = false);
                                } else {
                                  _storesLoading = false;
                                }
                              }
                            },
                          ),
                          _select(
                            '매장',
                            'store_id',
                            {
                              for (final s in _stores)
                                s.id: '${s.name}${s.isClosed ? ' (폐점)' : ''}',
                            },
                            update,
                            enabled: !_storesLoading,
                          ),
                          _select(
                            '업무 구분',
                            'work_type_id',
                            {
                              for (final c
                                  in _codes['SERVICE_WORK_TYPE'] ??
                                      <CodeItem>[])
                                c.id: '${c.code} · ${c.name}',
                            },
                            update,
                            after: (value) {
                              if (value != null) {
                                update(() {
                                  final missing =
                                      (_filters['missing'] as String? ?? '')
                                          .split(',')
                                        ..remove('work_type');
                                  _set(
                                    'missing',
                                    missing
                                        .where((s) => s.isNotEmpty)
                                        .join(','),
                                  );
                                });
                              }
                            },
                          ),
                          _select(
                            '업무 구분 미지정',
                            'missing',
                            const {'work_type': '미분류만'},
                            update,
                            after: (value) {
                              if (value == 'work_type') {
                                update(() => _filters.remove('work_type_id'));
                              }
                            },
                          ),
                          _select(
                            '서비스구분',
                            'category_id',
                            _codeChoices('SERVICE_CATEGORY'),
                            update,
                            after: (_) =>
                                update(() => _filters.remove('symptom_id')),
                          ),
                          _select(
                            '세부분류',
                            'symptom_id',
                            _filters['category_id'] == null
                                ? {}
                                : _codeChoices(
                                    'SERVICE_SYMPTOM',
                                    parent: _filters['category_id'] as String?,
                                  ),
                            update,
                            enabled:
                                _filters['category_id'] != null &&
                                _codeChoices(
                                  'SERVICE_SYMPTOM',
                                  parent: _filters['category_id'] as String?,
                                ).isNotEmpty,
                          ),
                          _select(
                            '과실',
                            'fault_id',
                            _codeChoices('SERVICE_FAULT'),
                            update,
                          ),
                          _select(
                            '대응인원',
                            'responder_id',
                            _codeChoices('SERVICE_RESPONDER'),
                            update,
                          ),
                          SizedBox(
                            width: AppTheme.isWide(context)
                                ? 180
                                : double.infinity,
                            child: DropdownButtonFormField<String>(
                              initialValue: _filters['only_open'] == true
                                  ? 'open'
                                  : (_filters['status'] == 'COMPLETED'
                                        ? 'done'
                                        : ''),
                              decoration: const InputDecoration(
                                labelText: '상태',
                              ),
                              isExpanded: true,
                              items: const [
                                DropdownMenuItem(value: '', child: Text('전체')),
                                DropdownMenuItem(
                                  value: 'open',
                                  child: Text('미종결'),
                                ),
                                DropdownMenuItem(
                                  value: 'done',
                                  child: Text('종결'),
                                ),
                              ],
                              onChanged: (v) => update(() {
                                _set('only_open', v == 'open' ? true : null);
                                _set(
                                  'status',
                                  v == 'done' ? 'COMPLETED' : null,
                                );
                              }),
                            ),
                          ),
                          SizedBox(
                            width: AppTheme.isWide(context)
                                ? 180
                                : double.infinity,
                            child: DropdownButtonFormField<String>(
                              initialValue:
                                  _filters['rental_unreturned'] == true
                                  ? 'unreturned'
                                  : (_filters['is_rental'] == true
                                        ? 'rental'
                                        : ''),
                              decoration: const InputDecoration(
                                labelText: '렌탈',
                              ),
                              isExpanded: true,
                              items: const [
                                DropdownMenuItem(value: '', child: Text('전체')),
                                DropdownMenuItem(
                                  value: 'rental',
                                  child: Text('렌탈만'),
                                ),
                                DropdownMenuItem(
                                  value: 'unreturned',
                                  child: Text('미회수'),
                                ),
                              ],
                              onChanged: (v) => update(() {
                                _set(
                                  'is_rental',
                                  v == 'rental' || v == 'unreturned'
                                      ? true
                                      : null,
                                );
                                _set(
                                  'rental_unreturned',
                                  v == 'unreturned' ? true : null,
                                );
                              }),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('적용'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted) _refresh();
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
        '대응기록_${ServiceRepository.dateOnly(DateTime.now())}.xlsx',
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
      title: const Text('대응 기록'),
      actions: [
        FilledButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add),
          label: const Text('접수'),
        ),
        TextButton.icon(
          onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.download),
          label: Text(_exporting ? '저장 중' : '엑셀'),
        ),
        const SizedBox(width: AppSpace.lg),
      ],
    ),
    body: PageBody(
      child: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final entry in [
                  (0, '접수', _searchCounts?[0] ?? _summary?.total),
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
          const FormGap(),
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
              OutlinedButton.icon(
                onPressed: _editFilters,
                icon: const Icon(Icons.filter_list),
                label: const Text('상세 조건'),
              ),
              DropdownButton<String>(
                value: _sort,
                items: [
                  for (final e in _sortLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) {
                  if (v != null) {
                    _sort = v;
                    _refresh();
                  }
                },
              ),
            ],
          ),
          const FormGap(),
          Wrap(
            runSpacing: 12,
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '검색 ${Fmt.number(_total)}건 / 전체 ${Fmt.number(_overallTotal)}건 · 표시 ${Fmt.number(_rows.length)}건',
              ),
              for (final item in [
                ('번호', 'ticket_no'),
                ('브랜드', 'brand'),
                ('매장', 'store'),
                ('발생일', 'received'),
                ('대응일', 'completed'),
                ('상태', 'status'),
              ])
                TextButton(
                  onPressed: () {
                    _sort = _sort == '${item.$2}_asc'
                        ? '${item.$2}_desc'
                        : '${item.$2}_asc';
                    _refresh();
                  },
                  child: Text(
                    '${item.$1}${_sort.startsWith(item.$2) ? (_sort.endsWith('asc') ? ' ↑' : ' ↓') : ''}',
                  ),
                ),
            ],
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
                                      message: '대응 기록을 불러오지 못했습니다',
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
                                          ? '아직 등록된 대응 기록이 없습니다'
                                          : '검색 조건에 맞는 대응 기록이 없습니다',
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
