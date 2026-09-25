import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/inventory_repository.dart';
import '../async_view.dart';
import '../common/common.dart';
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
  const EquipmentNavigation({super.key, required this.open, required super.child});
  final void Function(EquipmentTab, Map<String, dynamic>) open;
  @override
  bool updateShouldNotify(EquipmentNavigation oldWidget) => false;
}

class EquipmentPage extends StatefulWidget {
  const EquipmentPage({super.key, this.tab = EquipmentTab.overview, this.filters = const {}});
  final EquipmentTab tab;
  final Map<String, dynamic> filters;

  static Future<void> open(BuildContext context, {EquipmentTab tab = EquipmentTab.overview,
    String? brandId, String? storeId, String? locationId, String? categoryId, String? statusItemId}) async {
    if (tab == EquipmentTab.stores && storeId != null) {
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StoreDetailPage(storeId: storeId)));
      return;
    }
    final filters = <String, dynamic>{
      if (brandId != null) 'brand_id': brandId,
      if (storeId != null) 'store_id': storeId,
      if (locationId != null) 'location_id': locationId,
      if (locationId != null) 'at_store': false
      else if (brandId != null && tab == EquipmentTab.assets) 'at_store': true,
      if (categoryId != null) 'category_id': categoryId,
      if (statusItemId != null)
        (AssetStatus.values.any((s) => s.value == statusItemId) ? 'status' : 'status_item_id'): statusItemId,
    };
    final page = context.findAncestorStateOfType<EquipmentPageState>();
    final navigation = context.getInheritedWidgetOfExactType<EquipmentNavigation>();
    if (page != null) {
      page.show(tab, filters);
    } else if (navigation != null) {
      navigation.open(tab, filters);
    } else {
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('장비·매장')), body: EquipmentPage(tab: tab, filters: filters))));
    }
  }

  @override
  State<EquipmentPage> createState() => EquipmentPageState();
}

class EquipmentPageState extends State<EquipmentPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this, initialIndex: widget.tab.index);
  final _list = GlobalKey<InventoryListTabState>();
  final _stores = GlobalKey<StoreTabState>();
  int _revision = 0;
  @override
  void initState() { super.initState(); _tabs.addListener(_tabChanged); }
  void _tabChanged() { setState(() {}); }
  @override
  void dispose() { _tabs.removeListener(_tabChanged); _tabs.dispose(); super.dispose(); }

  void show(EquipmentTab tab, Map<String, dynamic> filters) {
    if (tab == EquipmentTab.assets) _list.currentState?.applyFilters(filters);
    if (tab == EquipmentTab.stores) _stores.currentState?.selectBrand(filters['brand_id'] as String?);
    _tabs.animateTo(tab.index);
  }

  void _changed() => setState(() => _revision++);

  @override
  Widget build(BuildContext context) => Builder(builder: (context) => Column(children: [
    AppBar(primary: false, automaticallyImplyLeading: false, titleSpacing: AppSpace.lg, actions: [
      TextButton.icon(icon: const Icon(Icons.add), label: const Text('장비 등록'), onPressed: () async {
        final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const AssetFormPage()));
        if (saved == true && mounted) _changed();
      }),
      TextButton.icon(icon: const Icon(Icons.download), label: const Text('엑셀'), onPressed: () => _list.currentState?.export(all: _tabs.index != EquipmentTab.assets.index)),
      PopupMenuButton<String>(tooltip: '더보기', onSelected: (_) => _changed(),
        itemBuilder: (_) => [const PopupMenuItem(value: 'refresh', child: Text('새로고침'))]),
      const SizedBox(width: AppSpace.lg),
    ]),
    TabBar(controller: _tabs, isScrollable: true, tabs: const [
      Tab(icon: Icon(Icons.dashboard_outlined), text: '현황'),
      Tab(icon: Icon(Icons.store_outlined), text: '매장'),
      Tab(icon: Icon(Icons.inventory_2_outlined), text: '장비 목록'),
      Tab(icon: Icon(Icons.place_outlined), text: '위치'),
    ]),
    _EquipmentSummary(key: ValueKey('summary:$_revision')),
    Expanded(child: IndexedStack(index: _tabs.index, children: [
      InventoryOverviewTab(key: ValueKey('overview:$_revision'), onChanged: _changed, onDrill: (filters) {
        EquipmentPage.open(context, tab: filters.containsKey('brand_id') ? EquipmentTab.stores : EquipmentTab.assets,
          brandId: filters['brand_id'] as String?, locationId: filters['location_id'] as String?,
          categoryId: filters['category_id'] as String?, statusItemId: (filters['status_item_id'] ?? filters['status']) as String?);
      }),
      StoreTab(key: _stores, onChanged: _changed, initialBrandId: widget.tab == EquipmentTab.stores ? widget.filters['brand_id'] as String? : null, revision: _revision),
      InventoryListTab(key: _list, initialFilters: widget.tab == EquipmentTab.assets ? widget.filters : const {}, revision: _revision, onChanged: _changed),
      LocationPage(embedded: true, onChanged: _changed),
    ])),
  ]));
}


class _EquipmentSummary extends StatelessWidget {
  const _EquipmentSummary({super.key});
  @override
  Widget build(BuildContext context) => AsyncView<InventoryOverview>(
    load: context.read<InventoryRepository>().overview,
    builder: (context, data, reload) => PageBody(padding: EdgeInsets.fromLTRB(
      AppTheme.isWide(context) ? AppSpace.xl : AppSpace.lg, AppSpace.lg,
      AppTheme.isWide(context) ? AppSpace.xl : AppSpace.lg, 0), child: LayoutBuilder(
      builder: (context, constraints) => Row(children: [
        for (final item in <(String, int, Widget)>[
          ('전체 대수', data.total, const Icon(Icons.inventory_2_outlined)),
          ('매장 설치', data.byBrand.fold<int>(0, (sum, row) => sum + row.total), const Icon(Icons.store_outlined)),
          ('창고/사무실', data.byPlace.fold<int>(0, (sum, row) => sum + row.total), const Icon(Icons.place_outlined)),
        ]) ...[
          if (item.$1 != '전체 대수') const SizedBox(width: AppSpace.sm),
          Expanded(child: StatTile(label: item.$1, value: '${Fmt.number(item.$2)}대',
            iconWidget: item.$3, compact: !AppTheme.isWide(context))),
        ],
      ]),
    )),
  );
}
