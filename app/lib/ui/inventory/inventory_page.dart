import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
import 'asset_destination.dart';
import 'asset_form_page.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});
  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> with TickerProviderStateMixin {
  TabController? _tabs;
  List<CodeItem> _kinds = [];
  Map<String, dynamic> _filters = {};
  int _revision = 0, _listRevision = 0;
  final _loadKey = GlobalKey<AsyncViewState<List<CodeItem>>>();
  @override
  void dispose() { _tabs?.dispose(); super.dispose(); }

  void _drill(Map<String, dynamic> filters) {
    setState(() { _filters = filters; _listRevision++; });
    _tabs!.animateTo(_kinds.length + 1);
  }

  @override
  Widget build(BuildContext context) => AsyncView<List<CodeItem>>(
    key: _loadKey,
    load: () => inventoryLoad(context, () async {
      final group = await context.read<AdminRepository>().codeGroup('ASSET_CATEGORY');
      if (!mounted) return group.selectable;
      _kinds = group.selectable;
      _tabs?.dispose();
      _tabs = TabController(length: _kinds.length + 2, vsync: this);
      return _kinds;
    }),
    builder: (context, kinds, reload) => Column(children: [
      TabBar(controller: _tabs, isScrollable: true, tabs: [
        const Tab(text: '현황'), for (final k in kinds) Tab(text: k.name), const Tab(text: '목록'),
      ]),
      Expanded(child: TabBarView(controller: _tabs, children: [
        _OverviewTab(key: ValueKey('overview:$_revision'), onDrill: _drill, onChanged: () => setState(() => _revision++)),
        for (final k in kinds) _InventoryList(key: ValueKey(k.id), category: k, revision: _revision, onChanged: () => setState(() => _revision++)),
        _InventoryList(key: ValueKey('list:$_listRevision'), initialFilters: _filters, revision: _revision,
          onChanged: () => setState(() => _revision++)),
      ])),
    ]),
  );
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({super.key, required this.onDrill, required this.onChanged});
  final ValueChanged<Map<String, dynamic>> onDrill;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => AsyncView<InventoryOverview>(
    load: () => inventoryLoad(context, context.read<InventoryRepository>().overview),
    builder: (context, data, reload) => ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [Expanded(child: Text('전체 ${data.total}대', style: Theme.of(context).textTheme.titleLarge)),
        TextButton.icon(icon: const Icon(Icons.download), label: const Text('엑셀'), onPressed: () => runGuarded(context, () async {
          final bytes = await context.read<InventoryRepository>().exportXlsx();
          await saveAndOpenDownload(bytes, '재고_${DateTime.now().millisecondsSinceEpoch}.xlsx');
        })),
      ]),
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
    ]),
  );

  Widget _table(BuildContext context, String title, List<OverviewRow> rows, List<CodeItem> kinds, String axis) {
    final columns = <String, String>{for (final k in kinds) k.id: k.name,
      if (rows.any((r) => r.counts.containsKey('-'))) '-': '미분류'};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20), Text(title, style: Theme.of(context).textTheme.titleMedium),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
        columns: [const DataColumn(label: Text('구분')),
          for (final c in columns.values) DataColumn(label: Text(c), numeric: true),
          const DataColumn(label: Text('합계'), numeric: true)],
        rows: [for (final row in rows) DataRow(cells: [DataCell(Text(row.label)),
          for (final c in columns.keys) DataCell(Text('${row.counts[c] ?? 0}'), onTap: () => _open(axis, row.key, c)),
          DataCell(Text('${row.total}'), onTap: () => _open(axis, row.key, null)),
        ])],
      )),
    ]);
  }

  void _open(String axis, String key, String? category) => onDrill({
    if (category != null) 'category_id': category,
    if (axis == 'status_item_id' && AssetStatus.values.any((s) => s.value == key)) 'status': key
      else axis: key,
    if (axis == 'brand_id') 'at_store': true,
    if (axis == 'location_id') 'at_store': false,
  });
}

class _InventoryList extends StatefulWidget {
  const _InventoryList({super.key, this.category, this.initialFilters = const {}, required this.revision, required this.onChanged});
  final CodeItem? category;
  final int revision;
  final Map<String, dynamic> initialFilters;
  final VoidCallback onChanged;
  @override
  State<_InventoryList> createState() => _InventoryListState();
}

class _InventoryListState extends State<_InventoryList> {
  final _search = TextEditingController();
  final _selected = <String>{};
  final _viewKey = GlobalKey<AsyncViewState<List<Asset>>>();
  late final Map<String, dynamic> _filters = {...widget.initialFilters,
    if (widget.category != null) 'category_id': widget.category!.id};
  List<CodeItem> _kinds = [], _statuses = [];
  List<Store> _stores = [];
  List<BrandSummary> _brands = [];
  List<StorageLocation> _places = [];
  bool _ready = false, _exporting = false;
  String _sort = 'kind_serial';
  int _page = 1, _pages = 1, _total = 0, _request = 0;
  @override
  void initState() { super.initState(); _search.text = _filters['q'] as String? ?? ''; _loadChoices(); }
  @override
  void didUpdateWidget(covariant _InventoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _selected.clear();
      _viewKey.currentState?.reload();
    }
  }
  @override
  void dispose() { _search.dispose(); super.dispose(); }

  Future<void> _loadChoices() async {
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
    final all = widget.category != null || filters.values.contains('-') || filters.containsKey('status');
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

  Future<void> _export() async {
    setState(() => _exporting = true);
    await runGuarded(context, () async {
      // UUID 필터로 표현할 수 없는 미지정 셀은 서버 엑셀 계약에 없다.
      if (_filters.values.contains('-') || _filters.containsKey('status')) {
        inventoryMessage(context, '미지정 또는 기본 상태 조건은 서버 엑셀에서 지원하지 않습니다. 세부 상태·종류·브랜드·위치를 선택해 주세요.');
        return;
      }
      final bytes = await context.read<InventoryRepository>().exportXlsx(filters: _filters);
      await saveAndOpenDownload(bytes, '재고_${DateTime.now().millisecondsSinceEpoch}.xlsx');
    });
    if (mounted) setState(() => _exporting = false);
  }

  Widget _filter(String label, String key, Map<String, String> choices) => SizedBox(width: 180,
    child: inventoryChoice(label, _filters[key] as String?, {
      if (_filters[key] == '-') '-': '미지정', ...choices,
    }, (v) { if (key == 'brand_id') _filters.remove('store_id'); _set(key, v); }, empty: '전체'));

  @override
  Widget build(BuildContext context) {
    if (!_ready) return Center(child: TextButton(onPressed: _loadChoices, child: const Text('필터 불러오기')));
    return Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        Row(children: [Expanded(child: TextField(controller: _search,
          decoration: const InputDecoration(hintText: 'S/N · 품명 · 매장 · 메모 검색', prefixIcon: Icon(Icons.search)),
          onSubmitted: (v) => _set('q', v.trim().isEmpty ? null : v.trim()))),
          IconButton(tooltip: '등록', icon: const Icon(Icons.add), onPressed: () async {
            final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const AssetFormPage()));
            if (saved == true && mounted) widget.onChanged();
          }),
          TextButton(onPressed: _exporting ? null : _export, child: const Text('엑셀')),
        ]),
        const SizedBox(height: 8),
        if (widget.category != null) SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          ChoiceChip(label: const Text('전체'), selected: !_filters.containsKey('at_store'), onSelected: (_) {
            _filters.remove('brand_id'); _filters.remove('location_id'); _set('at_store', null);
          }),
          for (final b in _brands) Padding(padding: const EdgeInsets.only(left: 6), child: ChoiceChip(
            label: Text(b.brandName), selected: _filters['at_store'] == true && _filters['brand_id'] == (b.brandId ?? '-'),
            onSelected: (_) { _filters.remove('location_id'); _filters['at_store'] = true; _set('brand_id', b.brandId ?? '-'); })),
          for (final l in _places) Padding(padding: const EdgeInsets.only(left: 6), child: ChoiceChip(
            label: Text(l.name), selected: _filters['at_store'] == false && _filters['location_id'] == l.id,
            onSelected: (_) { _filters.remove('brand_id'); _filters['at_store'] = false; _set('location_id', l.id); })),
        ])) else SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(spacing: 8, children: [
          if (_filters.containsKey('status')) InputChip(label: Text('기본 상태: ${AssetStatus.parse(_filters['status'] as String?).label}'), onDeleted: () => _set('status', null)),
          _filter('종류', 'category_id', {for (final c in _kinds) c.id: c.name}),
          _filter('세부 상태', 'status_item_id', {for (final c in _statuses) c.id: c.name}),
          _filter('브랜드', 'brand_id', {for (final b in _brands) if (b.brandId != null) b.brandId!: b.brandName}),
          _filter('매장', 'store_id', {for (final s in _stores.where((s) => _filters['brand_id'] == null || s.brandId == _filters['brand_id'])) s.id: s.name}),
          _filter('위치', 'location_id', {for (final l in _places) l.id: l.display}),
          SizedBox(width: 150, child: inventoryChoice('위치 구분', _filters['at_store']?.toString(),
            const {'true': '매장', 'false': '미설치'}, (v) => _set('at_store', v == null ? null : v == 'true'), empty: '전체')),
          SizedBox(width: 150, child: inventoryChoice('정렬', _sort, const {'created_desc': '최근 등록', 'serial_asc': 'S/N', 'kind_serial': '종류 · S/N', 'updated_desc': '최근 수정'},
            (v) { _sort = v ?? 'kind_serial'; _set('sort', _sort); })),
          TextButton(onPressed: () { _filters.clear(); _search.clear(); _set('q', null); }, child: const Text('초기화')),
        ])),
      ])),
      Expanded(child: AsyncView<List<Asset>>(key: _viewKey, load: _load,
        builder: (context, assets, reload) => Column(children: [
          Text('$_total대'),
          Expanded(child: widget.category != null ? _grouped(assets, reload)
            : ListView(children: [for (final a in assets) _tile(a, reload, check: true)])),
          if (widget.category == null && _pages > 1) Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: _page <= 1 ? null : () { setState(() => _page--); reload(); }, icon: const Icon(Icons.chevron_left)),
            Text('$_page / $_pages'),
            IconButton(onPressed: _page >= _pages ? null : () { setState(() => _page++); reload(); }, icon: const Icon(Icons.chevron_right)),
          ]),
        ]))),
      if (_selected.isNotEmpty) SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(8),
        child: FilledButton(onPressed: () async {
          if (await showAssetMoveDialog(context, _selected.toList(), bulk: true) && mounted) {
            setState(() => _selected.clear()); widget.onChanged();
          }
        }, child: Text('선택 ${_selected.length}대 일괄 변경')))),
    ]);
  }

  Widget _grouped(List<Asset> assets, VoidCallback reload) {
    final groups = <String, List<Asset>>{};
    for (final a in assets) {
      final store = _stores.where((s) => s.id == a.storeId).firstOrNull;
      final key = a.storeId != null ? '매장에 있는 것 · ${store?.brandName ?? '미지정'} → ${store?.name ?? a.storeName ?? '-'}'
          : '미설치 · ${_places.where((l) => l.id == a.locationId).firstOrNull?.display ?? a.location?.display ?? '장소 없음'}';
      groups.putIfAbsent(key, () => []).add(a);
    }
    final keys = groups.keys.toList()..sort();
    return ListView(children: [for (final key in keys) ...[
      Padding(padding: const EdgeInsets.all(12), child: Text('$key (${groups[key]!.length}대)', style: const TextStyle(fontWeight: FontWeight.w700))),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
        columns: const [DataColumn(label: Text('S/N')), DataColumn(label: Text('품명')), DataColumn(label: Text('상태')), DataColumn(label: Text('세트'))],
        rows: [for (final a in groups[key]!) DataRow(cells: [
          DataCell(Text(a.serialNo ?? a.assetNo), onTap: () => _detail(a, reload)),
          DataCell(Text(a.modelName ?? a.name)), DataCell(StatusChip(label: _statusLabel(a), color: a.status.color)), DataCell(Text('${a.setNo}')),
        ])],
      )),
    ]]);
  }
  String _statusLabel(Asset a) => _statuses.where((s) => s.id == a.statusItemId).firstOrNull?.name ?? a.statusLabel;
  String _placeLabel(Asset a) => a.storeId != null
      ? _stores.where((s) => s.id == a.storeId).firstOrNull?.name ?? a.placeLabel
      : _places.where((l) => l.id == a.locationId).firstOrNull?.display ?? a.placeLabel;

  Widget _tile(Asset a, VoidCallback reload, {bool check = false}) => ListTile(
    leading: check ? Checkbox(value: _selected.contains(a.id), onChanged: (v) => setState(() {
      if (v == true) { _selected.add(a.id); } else { _selected.remove(a.id); }
    })) : null,
    title: Text('${a.serialNo ?? a.assetNo} · ${a.name}'),
    subtitle: Text('${_placeLabel(a)} · 세트 ${a.setNo}'),
    trailing: StatusChip(label: _statusLabel(a), color: a.status.color), onTap: () => _detail(a, reload));
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
    return Scaffold(appBar: AppBar(title: const Text('자산 상세')),
      body: AsyncView<(Asset, List<AssetMovement>, List<CodeItem>, List<Store>)>(
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
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(a.name, style: Theme.of(context).textTheme.titleLarge),
            Text('${a.assetNo} · ${a.serialNo ?? '-'}'),
            Text('${a.statusLabel} · ${a.placeLabel} · 세트 ${a.setNo}'),
            Text('품명 ${a.modelName ?? '-'} · 제조사 ${a.manufacturer ?? '-'}'),
            Text('설치일 ${Fmt.date(a.purchaseDate)}'), if (a.note != null) Text(a.note!),
            const SizedBox(height: 16),
            FilledButton.icon(icon: const Icon(Icons.swap_horiz), label: const Text('이동 / 상태 변경'), onPressed: () async {
              if (await showAssetMoveDialog(context, [a.id]) && context.mounted) reload();
            }),
            const SizedBox(height: 16), Text('이동 이력 (${movements.length}건)'),
            for (final m in movements) ListTile(contentPadding: EdgeInsets.zero,
              title: Text('${m.movementType.label} · ${status(m.fromStatusItemId, m.fromStatus)} → ${status(m.toStatusItemId, m.toStatus)}'),
              subtitle: Text('${store(m.fromStoreId)} → ${store(m.toStoreId)}\n${Fmt.dateTime(m.movedAt)}\n${m.reason ?? ''}')),
          ]);
        },
      ));
  }
}
