import '../common/section_main_reporter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/inventory_repository.dart';
import '../../data/store_repository.dart';
import '../async_view.dart';
import '../common/common.dart';
import '../common/download.dart';
import '../format.dart';
import '../theme.dart';
import '../inventory/asset_form_page.dart';
import '../../models/inventory.dart';
import '../inventory/inventory_page.dart';
import '../inventory/location_page.dart';
import '../store/store_page.dart';
import '../store/store_detail_page.dart';

enum EquipmentTab { overview, stores, assets, locations }

/// Lets links in sibling shell destinations activate the retained equipment page.
class EquipmentNavigation extends InheritedWidget {
  const EquipmentNavigation({
    super.key,
    required this.open,
    required super.child,
  });
  final void Function(EquipmentTab, Map<String, dynamic>) open;
  @override
  bool updateShouldNotify(EquipmentNavigation oldWidget) => false;
}

class EquipmentPage extends StatefulWidget {
  const EquipmentPage({
    super.key,
    this.tab = EquipmentTab.overview,
    this.filters = const {},
  });
  final EquipmentTab tab;
  final Map<String, dynamic> filters;

  static Future<void> open(
    BuildContext context, {
    EquipmentTab tab = EquipmentTab.overview,
    String? brandId,
    String? storeId,
    String? locationId,
    String? categoryId,
    String? statusItemId,
  }) async {
    if (tab == EquipmentTab.stores && storeId != null) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => StoreDetailPage(storeId: storeId),
        ),
      );
      return;
    }
    final filters = <String, dynamic>{
      if (brandId != null) 'brand_id': brandId,
      if (storeId != null) 'store_id': storeId,
      if (locationId != null) 'location_id': locationId,
      if (locationId != null)
        'at_store': false
      else if (brandId != null && tab == EquipmentTab.assets)
        'at_store': true,
      if (categoryId != null) 'category_id': categoryId,
      if (statusItemId != null)
        (AssetStatus.values
                    .where((value) => value != AssetStatus.unknown)
                    .any((s) => s.value == statusItemId)
                ? 'status'
                : 'status_item_id'):
            statusItemId,
    };
    final page = context.findAncestorStateOfType<EquipmentPageState>();
    final navigation = context
        .getInheritedWidgetOfExactType<EquipmentNavigation>();
    if (page != null) {
      page.show(tab, filters);
    } else if (navigation != null) {
      navigation.open(tab, filters);
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('장비·매장')),
            body: EquipmentPage(tab: tab, filters: filters),
          ),
        ),
      );
    }
  }

  @override
  State<EquipmentPage> createState() => EquipmentPageState();
}

class EquipmentPageState extends State<EquipmentPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 4,
    vsync: this,
    initialIndex: widget.tab.index,
  );
  final _list = GlobalKey<InventoryListTabState>();
  final _stores = GlobalKey<StoreTabState>();
  int _revision = 0;
  bool _exporting = false;
  final _visited = <int>{};
  @override
  void initState() {
    super.initState();
    _tabs.addListener(_tabChanged);
  }

  void _tabChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void show(EquipmentTab tab, Map<String, dynamic> filters) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (tab == EquipmentTab.assets) _list.currentState?.applyFilters(filters);
      if (tab == EquipmentTab.stores) {
        _stores.currentState?.selectBrand(filters['brand_id'] as String?);
      }
    });
    _tabs.animateTo(tab.index);
  }

  void _changed() {
    context.read<InventoryRepository>().invalidateOverview();
    setState(() => _revision++);
  }

  void backToMain() {
    if (_tabs.index == EquipmentTab.stores.index &&
        (_stores.currentState?.backToBrands() ?? false)) {
      return;
    }
    _tabs.animateTo(EquipmentTab.overview.index);
  }

  Future<void> _addAsset() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AssetFormPage()),
    );
    if (saved == true && mounted) _changed();
  }

  Future<void> _menuAction(String action) async {
    switch (action) {
      case 'export':
        if (_exporting) return;
        setState(() => _exporting = true);
        try {
          final list = _list.currentState;
          if (_tabs.index == EquipmentTab.assets.index && list != null) {
            await list.export();
          } else {
            await runGuarded(context, () async {
              final bytes = await context
                  .read<InventoryRepository>()
                  .exportXlsx();
              await saveAndOpenDownload(
                bytes,
                '재고_${DateTime.now().millisecondsSinceEpoch}.xlsx',
              );
            });
          }
        } finally {
          if (mounted) setState(() => _exporting = false);
        }
        return;
      case 'refresh':
        _changed();
        return;
    }
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) {
      _visited.add(_tabs.index);
      return SectionMainReporter(
        controller: _tabs,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: _tabs,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: const [
                      WorkspaceTab(
                        icon: Icon(Icons.dashboard_outlined),
                        text: '현황',
                      ),
                      WorkspaceTab(
                        icon: Icon(Icons.store_outlined),
                        text: '매장',
                      ),
                      WorkspaceTab(
                        icon: Icon(Icons.inventory_2_outlined),
                        text: '장비 목록',
                      ),
                      WorkspaceTab(
                        icon: Icon(Icons.place_outlined),
                        text: '위치',
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '더보기',
                  icon: const Icon(Icons.more_vert),
                  onSelected: _menuAction,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'export',
                      enabled: !_exporting,
                      child: Text(_exporting ? '엑셀 다운로드 중…' : '엑셀 다운로드'),
                    ),
                    const PopupMenuItem(value: 'refresh', child: Text('새로고침')),
                  ],
                ),
                const SizedBox(width: AppSpace.sm),
              ],
            ),
            if (_tabs.index == EquipmentTab.overview.index)
              _EquipmentSummary(key: ValueKey('summary:$_revision')),
            Expanded(
              child: IndexedStack(
                index: _tabs.index,
                children: [
                  !_visited.contains(0)
                      ? const SizedBox.shrink()
                      : InventoryOverviewTab(
                          key: ValueKey('overview:$_revision'),
                          onChanged: _changed,
                          onDrill: (filters) {
                            EquipmentPage.open(
                              context,
                              tab: filters.containsKey('brand_id')
                                  ? EquipmentTab.stores
                                  : EquipmentTab.assets,
                              brandId: filters['brand_id'] as String?,
                              locationId: filters['location_id'] as String?,
                              categoryId: filters['category_id'] as String?,
                              statusItemId:
                                  (filters['status_item_id'] ??
                                          filters['status'])
                                      as String?,
                            );
                          },
                        ),
                  !_visited.contains(1)
                      ? const SizedBox.shrink()
                      : StoreTab(
                          key: _stores,
                          onChanged: _changed,
                          initialBrandId: widget.tab == EquipmentTab.stores
                              ? widget.filters['brand_id'] as String?
                              : null,
                          revision: _revision,
                        ),
                  !_visited.contains(2)
                      ? const SizedBox.shrink()
                      : Scaffold(
                          floatingActionButtonLocation:
                              FloatingActionButtonLocation.endFloat,
                          floatingActionButton: FloatingActionButton.extended(
                            heroTag: 'create-asset',
                            tooltip: '장비 등록',
                            onPressed: _addAsset,
                            icon: const Icon(Icons.inventory_2_outlined),
                            label: const Text('+'),
                          ),
                          body: InventoryListTab(
                            key: _list,
                            initialFilters: widget.tab == EquipmentTab.assets
                                ? widget.filters
                                : const {},
                            revision: _revision,
                            onChanged: _changed,
                          ),
                        ),
                  !_visited.contains(3)
                      ? const SizedBox.shrink()
                      : LocationPage(embedded: true, onChanged: _changed),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _EquipmentSummary extends StatelessWidget {
  const _EquipmentSummary({super.key});

  int _kindCount(InventoryOverview overview, String code) {
    final ids = overview.kinds
        .where((kind) => kind.code == code)
        .map((kind) => kind.id)
        .toSet();
    return overview.byStatus.fold(
      0,
      (sum, row) =>
          sum +
          row.counts.entries
              .where((entry) => ids.contains(entry.key))
              .fold<int>(0, (count, entry) => count + entry.value),
    );
  }

  @override
  Widget build(BuildContext context) => AsyncView<(InventoryOverview, int)>(
    load: () async {
      final inventory = context.read<InventoryRepository>();
      final stores = context.read<StoreRepository>();
      final overview = await inventory.overview();
      final openStores = await stores.list(
        size: 1,
        includeClosed: false,
        includeInactive: false,
      );
      return (overview, openStores.total);
    },
    builder: (context, data, reload) => PageBody.workspace(
      child: LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            for (final item in <(String, int, Widget, String)>[
              (
                '로봇팔',
                _kindCount(data.$1, 'ROBOT_ARM'),
                const Icon(Icons.inventory_2_outlined),
                '대',
              ),
              (
                '제어박스',
                _kindCount(data.$1, 'CONTROL_BOX'),
                const Icon(Icons.developer_board_outlined),
                '대',
              ),
              ('운영 매장', data.$2, const Icon(Icons.store_outlined), ''),
              (
                '창고/사무실',
                data.$1.byPlace.fold<int>(0, (sum, row) => sum + row.total),
                const Icon(Icons.place_outlined),
                '대',
              ),
            ])
              SizedBox(
                width:
                    (constraints.maxWidth -
                        AppSpace.sm * (constraints.maxWidth >= 600 ? 3 : 1)) /
                    (constraints.maxWidth >= 600 ? 4 : 2),
                child: StatTile(
                  label: item.$1,
                  value: '${Fmt.number(item.$2)}${item.$4}',
                  iconWidget: item.$3,
                  compact: true,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
