import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/inventory.dart';
import '../../models/store.dart';
import '../async_view.dart';
import '../common/download.dart';
import '../format.dart';
import '../service/service_detail_page.dart';
import '../theme.dart';
import 'asset_actions.dart';
import 'asset_destination.dart';
import '../equipment/equipment_page.dart';

class InventoryOverviewTab extends StatelessWidget {
  const InventoryOverviewTab({super.key, required this.onDrill, required this.onChanged});
  final ValueChanged<Map<String, dynamic>> onDrill;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => AsyncView<InventoryOverview>(
    load: () => inventoryLoad(context, context.read<InventoryRepository>().overview),
    builder: (context, data, reload) => PageBody(child: ListView(padding: EdgeInsets.zero, children: [
      LayoutBuilder(builder: (context, constraints) => Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: [
        for (final item in <(String, int, IconData)>[
          ('전체 대수', data.total, Icons.precision_manufacturing),
          ('매장 설치', data.byBrand.fold<int>(0, (sum, row) => sum + row.total), Icons.store),
          ('창고/사무실', data.byPlace.fold<int>(0, (sum, row) => sum + row.total), Icons.warehouse_outlined),
        ]) SizedBox(width: constraints.maxWidth < 500 ? constraints.maxWidth : (constraints.maxWidth - AppSpace.sm * 2) / 3,
          child: StatTile(label: item.$1, value: '${Fmt.number(item.$2)}대', icon: item.$3)),
      ])),
      _table(context, '상태 × 종류', data.byStatus, data.kinds, 'status_item_id'),
      _table(context, '브랜드 × 종류 (매장에 있는 것)', data.byBrand, data.kinds, 'brand_id'),
      _table(context, '장소 × 종류 (미설치)', data.byPlace, data.kinds, 'location_id'),
      const SizedBox(height: 16),
      Text('확인 필요 (${data.attention.length}대)', style: Theme.of(context).textTheme.titleMedium),
      for (final a in data.attention) ListTile(
        title: Text('${a.categoryName ?? a.name} · ${a.serialNo ?? a.assetNo}'),
        subtitle: Text([a.statusName, a.storeName ?? a.locationName, a.note].whereType<String>().join(' · ')),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => AssetDetailPage(assetId: a.id)));
          if (context.mounted) onChanged();
        }),
      const SizedBox(height: 16),
      Text('렌탈 중 (${data.rentals.length}대)', style: Theme.of(context).textTheme.titleMedium),
      for (final a in data.rentals) ListTile(
        title: Text('${a.serialNo ?? a.assetNo} · ${a.storeName ?? '매장 미지정'}'),
        subtitle: Text('${a.ticketNo ?? '기록 없음'} · 회수 예정 ${Fmt.date(a.dueDate)} · ${rentalDday(a.dday)}'),
        onTap: a.ticketId == null ? null : () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ServiceDetailPage(ticketId: a.ticketId!)));
          if (context.mounted) onChanged();
        }),
    ])),
  );

  Widget _table(BuildContext context, String title, List<OverviewRow> rows, List<CodeItem> kinds, String axis) {
    final columns = <String, String>{for (final k in kinds) k.id: k.name,
      if (rows.any((r) => r.counts.containsKey('-'))) '-': '미분류'};
    return SectionCard(title: title, child: ResponsiveTable.fromDataRows(
        columns: [const DataColumn(label: Text('구분')),
          for (final c in columns.entries) DataColumn(label: InkWell(onTap: () => EquipmentPage.open(context, tab: EquipmentTab.assets, categoryId: c.key), child: Text(c.value)), numeric: true),
          const DataColumn(label: Text('합계'), numeric: true)],
        rows: [for (final row in rows) DataRow(cells: [DataCell(Text(row.label), onTap: () => _open(axis, row.key, null)),
          for (final c in columns.keys) DataCell(Text(Fmt.number(row.counts[c] ?? 0)), onTap: () => _open(axis, row.key, c)),
          DataCell(Text(Fmt.number(row.total)), onTap: () => _open(axis, row.key, null)),
        ])],
      ));
  }

  void _open(String axis, String key, String? category) => onDrill({
    if (category != null) 'category_id': category,
    if (axis == 'status_item_id' && AssetStatus.values.any((s) => s.value == key)) 'status': key
      else axis: key,
    if (axis == 'brand_id') 'at_store': true,
    if (axis == 'location_id') 'at_store': false,
  });
}

class InventoryListTab extends StatefulWidget {
  const InventoryListTab({super.key, this.initialFilters = const {}, required this.revision, required this.onChanged});
  final int revision;
  final Map<String, dynamic> initialFilters;
  final VoidCallback onChanged;
  @override
  State<InventoryListTab> createState() => InventoryListTabState();
}

class InventoryListTabState extends State<InventoryListTab> {
  final _search = TextEditingController();
  final _selected = <String>{};
  final _viewKey = GlobalKey<AsyncViewState<List<Asset>>>();
  late final Map<String, dynamic> _filters = {...widget.initialFilters};
  List<CodeItem> _kinds = [], _statuses = [];
  List<Store> _stores = [];
  List<BrandSummary> _brands = [];
  List<StorageLocation> _places = [];
  bool _ready = false, _exporting = false, _choicesLoading = true;
  String _sort = 'kind_serial';
  int _page = 1, _pages = 1, _total = 0, _request = 0;
  @override
  void initState() { super.initState(); _search.text = _filters['q'] as String? ?? ''; _loadChoices(); }
  @override
  void didUpdateWidget(covariant InventoryListTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _selected.clear();
      _loadChoices();
      _viewKey.currentState?.reload();
    }
  }
  @override
  void dispose() { _search.dispose(); super.dispose(); }

  void applyFilters(Map<String, dynamic> filters) {
    setState(() { _filters..clear()..addAll(filters); _search.text = _filters['q'] as String? ?? ''; _page = 1; _selected.clear(); });
    _viewKey.currentState?.reload();
  }

  Future<void> _loadChoices() async {
    setState(() => _choicesLoading = true);
    await runGuarded(context, () async {
      final admin = context.read<AdminRepository>();
      final stores = context.read<StoreRepository>();
      final data = await Future.wait([admin.codeGroup('ASSET_CATEGORY'), admin.codeGroup('ASSET_STATUS'),
        stores.all(includeClosed: true), stores.brands(), context.read<InventoryRepository>().locations()]);
      if (!mounted) return;
      setState(() {
        _kinds = (data[0] as CodeGroup).items; _statuses = (data[1] as CodeGroup).items;
        _stores = data[2] as List<Store>; _brands = data[3] as List<BrandSummary>;
        _places = data[4] as List<StorageLocation>; _ready = true;
      });
    });
    if (mounted) setState(() => _choicesLoading = false);
  }
  void _set(String key, dynamic value) {
    setState(() {
      if (key == 'status_item_id') _filters.remove('status');
      if (value == null) { _filters.remove(key); } else { _filters[key] = value; }
      _page = 1; _selected.clear();
    });
    _viewKey.currentState?.reload();
  }
  Future<List<Asset>> _load() => inventoryLoad(context, () async {
    final request = ++_request;
    final filters = Map<String, dynamic>.from(_filters);
    var total = 0, pages = 1;
    final repo = context.read<InventoryRepository>();
    final all = filters.values.contains('-') || filters.containsKey('status');
    final assets = <Asset>[];
    var pageNo = all ? 1 : _page;
    while (true) {
      String? id(String key) => filters[key] == '-' ? null : filters[key] as String?;
      final page = await repo.list(page: pageNo++, size: all ? 200 : 50,
        query: id('q'), categoryId: id('category_id'), statusItemId: id('status_item_id'),
        status: filters['status'] == null ? null : AssetStatus.parse(id('status')),
        brandId: id('brand_id'), storeId: id('store_id'), locationId: id('location_id'),
        atStore: filters['at_store'] as bool?, sort: _sort, includeSublocations: false);
      assets.addAll(page.items); total = page.total; pages = page.pages;
      if (!all || !page.hasMore) break;
    }
    final result = assets.where((a) =>
      (!filters.containsKey('status') || a.statusItemId == null) &&
      (filters['category_id'] != '-' || a.categoryId == null) &&
      (filters['location_id'] != '-' || a.locationId == null) &&
      (filters['brand_id'] != '-' || _stores.where((s) => s.id == a.storeId).firstOrNull?.brandId == null)).toList();
    if (all) { total = result.length; pages = 1; }
    if (request == _request) { _total = total; _pages = pages; }
    return result;
  });

  Future<void> export({bool all = false}) async {
    final filters = all ? <String, dynamic>{} : Map<String, dynamic>.from(_filters);
    if (_exporting) return;
    setState(() => _exporting = true);
    await runGuarded(context, () async {
      // UUID 필터로 표현할 수 없는 미지정 셀은 서버 엑셀 계약에 없다.
      if (filters.values.contains('-') || filters.containsKey('status')) {
        inventoryMessage(context, '미지정 또는 기본 상태 조건은 서버 엑셀에서 지원하지 않습니다. 세부 상태·종류·브랜드·위치를 선택해 주세요.');
        return;
      }
      final bytes = await context.read<InventoryRepository>().exportXlsx(filters: filters);
      await saveAndOpenDownload(bytes, '재고_${DateTime.now().millisecondsSinceEpoch}.xlsx');
    });
    if (mounted) setState(() => _exporting = false);
  }

  List<String> get _appliedFilters => [
    for (final e in _filters.entries) switch (e.key) {
      'q' => '검색: ${e.value}',
      'category_id' => _kinds.where((c) => c.id == e.value).firstOrNull?.name ?? '종류 미지정',
      'status_item_id' => _statuses.where((c) => c.id == e.value).firstOrNull?.name ?? '상태 미지정',
      'brand_id' => _brands.where((b) => b.brandId == e.value).firstOrNull?.brandName ?? '브랜드 미지정',
      'store_id' => _stores.where((s) => s.id == e.value).firstOrNull?.name ?? '매장 미지정',
      'location_id' => _places.where((l) => l.id == e.value).firstOrNull?.display ?? '위치 미지정',
      'at_store' => e.value == true ? '매장' : '미설치',
      'status' => AssetStatus.parse(e.value as String?).label,
      _ => '정렬 적용',
    },
  ];

  Widget _filter(String label, String key, Map<String, String> choices) => ActionChip(
    label: Text('$label: ${choices[_filters[key]] ?? (_filters[key] == '-' ? '미지정' : '전체')}'),
    avatar: const Icon(Icons.expand_more, size: 18),
    onPressed: () async {
      final selected = await showModalBottomSheet<String>(context: context, showDragHandle: true,
        builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text('$label 전체'), onTap: () => Navigator.pop(context, '')),
          for (final choice in {if (_filters[key] == '-') '-': '미지정', ...choices}.entries)
            ListTile(title: Text(choice.value), selected: _filters[key] == choice.key,
              onTap: () => Navigator.pop(context, choice.key)),
        ])));
      if (selected == null || !mounted) return;
      if (key == 'brand_id') _filters.remove('store_id');
      _set(key, selected.isEmpty ? null : selected);
    });

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return _choicesLoading ? const LoadingState()
        : ErrorState(message: '검색 조건을 불러오지 못했습니다', onRetry: _loadChoices);
    }
    return PageBody(child: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        TextField(controller: _search,
          decoration: const InputDecoration(hintText: 'S/N · 품명 · 매장 · 메모 검색', prefixIcon: Icon(Icons.search)),
          onSubmitted: (v) => _set('q', v.trim().isEmpty ? null : v.trim())),
        const SizedBox(height: 8),
        FilterBar(
          appliedFilters: _appliedFilters,
          onReset: () { _filters.clear(); _search.clear(); _set('q', null); },
          children: [
          if (_filters.containsKey('status')) InputChip(label: Text('기본 상태: ${AssetStatus.parse(_filters['status'] as String?).label}'), onDeleted: () => _set('status', null)),
          _filter('종류', 'category_id', {for (final c in _kinds) c.id: c.name}),
          _filter('세부 상태', 'status_item_id', {for (final c in _statuses) c.id: c.name}),
          _filter('브랜드', 'brand_id', {for (final b in _brands) if (b.brandId != null) b.brandId!: b.brandName}),
          _filter('매장', 'store_id', {for (final s in _stores.where((s) => _filters['brand_id'] == null || s.brandId == _filters['brand_id'])) s.id: s.name}),
          _filter('위치', 'location_id', {for (final l in _places) l.id: l.display}),
          for (final option in <(String, bool?)>[('전체 위치', null), ('매장', true), ('미설치', false)])
            ChoiceChip(label: Text(option.$1), selected: _filters['at_store'] == option.$2, onSelected: (_) => _set('at_store', option.$2)),
          SizedBox(width: 150, child: inventoryChoice('정렬', _sort, const {'created_desc': '최근 등록', 'serial_asc': 'S/N', 'kind_serial': '종류 · S/N', 'updated_desc': '최근 수정'},
            (v) { _sort = v ?? 'kind_serial'; _set('sort', _sort); })),
        ]),
      ])),
      Expanded(child: AsyncView<List<Asset>>(key: _viewKey, load: _load,
        builder: (context, assets, reload) => Column(children: [
          Text('${Fmt.number(_total)}대'),
          Expanded(child: assets.isEmpty ? const EmptyState(message: '아직 등록된 자산이 없습니다') : ListView(children: [ResponsiveTable<Asset>(
              rows: assets, onTap: (a) => _detail(a, reload),
              columns: [
                TableColumn(label: 'S/N', cell: (a) => Row(mainAxisSize: MainAxisSize.min, children: [
                  Checkbox(value: _selected.contains(a.id), onChanged: (v) => setState(() {
                    if (v == true) { _selected.add(a.id); } else { _selected.remove(a.id); }
                  })),
                  Flexible(child: Text(a.serialNo ?? a.assetNo)),
                ])),
                TableColumn(label: '품명', cell: (a) => Text(a.name)),
                TableColumn(label: '상태', cell: (a) => StatusChip(label: _statusLabel(a), color: a.status.color)),
                TableColumn(label: '위치', cell: (a) => Text(_placeLabel(a))),
                TableColumn(label: '세트', numeric: true, cell: (a) => Text(Fmt.number(a.setNo))),
                TableColumn(label: '작업', cell: _actions),
              ],
            )])),
          if (_pages > 1) Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: _page <= 1 ? null : () { setState(() => _page--); reload(); }, icon: const Icon(Icons.chevron_left)),
            Text('$_page / $_pages'),
            IconButton(onPressed: _page >= _pages ? null : () { setState(() => _page++); reload(); }, icon: const Icon(Icons.chevron_right)),
          ]),
        ]))),
      if (_selected.isNotEmpty) SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(8),
        child: OutlinedButton(onPressed: () async {
          if (await showAssetMoveDialog(context, _selected.toList(), bulk: true) && mounted) {
            setState(() => _selected.clear()); widget.onChanged();
          }
        }, child: Text('선택 ${_selected.length}대 일괄 변경')))),
    ]));
  }

  String _statusLabel(Asset a) => _statuses.where((s) => s.id == a.statusItemId).firstOrNull?.name ?? a.statusLabel;
  String _placeLabel(Asset a) => a.storeId != null
      ? _stores.where((s) => s.id == a.storeId).firstOrNull?.name ?? a.placeLabel
      : _places.where((l) => l.id == a.locationId).firstOrNull?.display ?? a.placeLabel;

  Widget _actions(Asset a) => AssetActionsMenu(key: ValueKey(a.id), assetId: a.id,
    label: '${a.name} S/N ${a.serialNo ?? a.assetNo}', atStore: a.storeId != null,
    onChanged: widget.onChanged);
  Future<void> _detail(Asset a, VoidCallback reload) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AssetDetailPage(assetId: a.id)));
    if (mounted) widget.onChanged();
  }
}

class AssetDetailPage extends StatelessWidget {
  const AssetDetailPage({super.key, required this.assetId});
  final String assetId;
  @override
  Widget build(BuildContext context) {
    final repo = context.read<InventoryRepository>();
    return Scaffold(appBar: AppBar(title: const Text('자산 상세'),
      actions: [AssetDeleteButton(assetId: assetId)]),
      body: PageBody(child: AsyncView<(Asset, List<AssetMovement>, List<CodeItem>, List<Store>)>(
        load: () => inventoryLoad(context, () async {
          final data = await Future.wait([repo.get(assetId),
            context.read<AdminRepository>().codeGroup('ASSET_STATUS'), context.read<StoreRepository>().all(includeClosed: true)]);
          final movements = <AssetMovement>[];
          var pageNo = 1;
          while (true) {
            final page = await repo.movements(assetId, page: pageNo++, size: 200);
            movements.addAll(page.items);
            if (!page.hasMore) break;
          }
          return (data[0] as Asset, movements, (data[1] as CodeGroup).items, data[2] as List<Store>);
        }),
        builder: (context, data, reload) {
          final (a, movements, statuses, stores) = data;
          String status(String? id, AssetStatus? fallback) => statuses.where((s) => s.id == id).firstOrNull?.name ?? fallback?.label ?? '-';
          String store(String? id) => stores.where((s) => s.id == id).firstOrNull?.name ?? (id == null ? '-' : '삭제된 매장');
          return Column(children: [Expanded(child: ListView(padding: EdgeInsets.zero, children: [
            SectionCard(title: '기본 정보', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(a.name, style: Theme.of(context).textTheme.titleLarge),
            Text('${a.assetNo} · ${a.serialNo ?? '-'}'),
            Text('${a.statusLabel} · ${a.placeLabel} · 세트 ${a.setNo}'),
            if (a.storeId != null) TextButton.icon(icon: const Icon(Icons.store_outlined),
              label: Text(store(a.storeId)), onPressed: () async {
                await EquipmentPage.open(context, tab: EquipmentTab.stores, storeId: a.storeId);
                if (context.mounted) reload();
              }),
            Text('품명 ${a.modelName ?? '-'} · 제조사 ${a.manufacturer ?? '-'}'),
            Text('설치일 ${Fmt.date(a.purchaseDate)}'), if (a.note != null) Text(a.note!),
            const SizedBox(height: 16),
            ])),

            const FormGap(),
            SectionCard(title: '이동 이력 (${Fmt.number(movements.length)}건)',
              child: ResponsiveTable<AssetMovement>(columns: [
                TableColumn(label: '이동', cell: (m) => Text(m.movementType.label)),
                TableColumn(label: '상태', cell: (m) => Text('${status(m.fromStatusItemId, m.fromStatus)} → ${status(m.toStatusItemId, m.toStatus)}')),
                TableColumn(label: '매장', cell: (m) => Text('${store(m.fromStoreId)} → ${store(m.toStoreId)}')),
                TableColumn(label: '일시', cell: (m) => Text(Fmt.dateTime(m.movedAt))),
                TableColumn(label: '메모', cell: (m) => Text(m.reason ?? '-')),
              ], rows: movements)),
          ])), FormActions(child: FilledButton.icon(icon: const Icon(Icons.swap_horiz), label: const Text('이동 / 상태 변경'), onPressed: () async {
              if (await performAssetAction(context, AssetAction.move,
                  assetId: a.id, label: '${a.name} S/N ${a.serialNo ?? a.assetNo}') && context.mounted) {
                reload();
              }
            }))]);
        },
      )));
  }
}
