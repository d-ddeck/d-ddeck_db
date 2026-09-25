import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/store_repository.dart';
import '../../models/store.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';
import '../inventory/asset_destination.dart';
import 'store_detail_page.dart';
import 'store_form_page.dart';

/// 매장 화면.
///
/// 브랜드 -> 매장 -> 보유 장비의 세 단계다. 구 서버가 이 순서로 읽혔고, 팀이
/// "바른치킨 강남역점에 뭐가 들어가 있지"를 그 순서로 묻기 때문이다.
///
/// 첫 화면은 브랜드 카드다. 매장 73곳을 한 줄로 늘어놓으면 찾을 수가 없다.
class StorePage extends StatefulWidget {
  const StorePage({super.key});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  final _searchCtl = TextEditingController();
  String? _brandId;
  String _brandName = '';
  String _query = '';
  bool _includeClosed = false;

  int _revision = 0;

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  void _pickBrand(BrandSummary? brand) {
    setState(() {
      _brandId = brand?.brandId;
      _brandName = brand?.brandName ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<StoreRepository>();

    // 브랜드를 고르기 전에는 브랜드 카드만 보여 준다.
    if (_brandId == null && _brandName.isEmpty && _query.isEmpty && !_includeClosed) {
      return PageBody(child: AsyncView<List<BrandSummary>>(
        key: ValueKey('brands:$_revision'),
        load: () => inventoryLoad(context, repo.brands),
        builder: (context, brands, reload) => _BrandGrid(
          brands: brands,
          onPick: _pickBrand,
          searchField: _buildSearch(),
          onRefresh: reload,
        ),
      ));
    }

    return PageBody(child: Column(
      children: [
        _buildSearch(),
        if (_brandName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.arrow_back, size: 18),
                  label: Text(_brandName),
                  onPressed: () => _pickBrand(null),
                ),
              ],
            ),
          ),
        Expanded(
          child: AsyncView<PagedStores>(
            key: ValueKey('$_brandId|$_brandName|$_query|$_includeClosed|$_revision'),
            load: () => inventoryLoad(context, () async {
              final items = <Store>[];
              var pageNo = 1;
              while (true) {
                final page = await repo.list(
                  page: pageNo++,
                  brandId: _brandId,
                  query: _query.isEmpty ? null : _query,
                  includeClosed: _includeClosed,
                  size: 200,
                );
                items.addAll(page.items.where((s) => _brandId != null || _brandName.isEmpty || s.brandId == null));
                if (!page.hasMore) break;
              }
              return PagedStores(items, items.length);
            }),
            emptyCheck: (d) => d.items.isEmpty,
            emptyMessage: '아직 등록된 매장이 없습니다',
            builder: (context, data, reload) => _StoreList(
              stores: data.items,
              total: data.total,
              onRefresh: reload,
            ),
          ),
        ),
      ],
    ));
  }

  Future<void> _addStore() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const StoreFormPage()),
    );
    if (saved == true && mounted) setState(() => _revision++);
  }

  Widget _buildSearch() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Align(alignment: Alignment.centerRight, child: FilledButton.icon(
      onPressed: _addStore, icon: const Icon(Icons.add), label: const Text('매장 등록'))),
    FilterBar(
      appliedFilters: [if (_query.isNotEmpty) '검색: $_query', if (_includeClosed) '폐점 포함', if (_brandName.isNotEmpty) _brandName],
      onReset: () => setState(() { _query = ''; _searchCtl.clear(); _includeClosed = false; _brandId = null; _brandName = ''; }),
      children: [
        SizedBox(width: AppTheme.isWide(context) ? 360 : double.infinity, child: _searchBox()),
        FilterChip(label: const Text('폐점 포함'), selected: _includeClosed,
          onSelected: (v) => setState(() => _includeClosed = v)),
      ],
    ),
  ]);

  Widget _searchBox() => Builder(
        builder: (context) => TextField(
          controller: _searchCtl,
          decoration: InputDecoration(
            hintText: '매장명 · 메모 검색',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchCtl.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (v) => setState(() => _query = v.trim()),
        ),
      );
}

/// AsyncView 가 제네릭 하나만 받아서, 목록과 합계를 같이 넘기려고 둔 묶음.
class PagedStores {
  const PagedStores(this.items, this.total);
  final List<Store> items;
  final int total;
}

class _BrandGrid extends StatelessWidget {
  const _BrandGrid({
    required this.brands,
    required this.onPick,
    required this.searchField,
    required this.onRefresh,
  });

  final List<BrandSummary> brands;
  final ValueChanged<BrandSummary> onPick;
  final Widget searchField;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final wide = AppTheme.isWide(context);
    final totalStores = brands.fold<int>(0, (a, b) => a + b.storeCount);
    final totalAssets = brands.fold<int>(0, (a, b) => a + b.assetCount);

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          searchField,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: '전체 매장',
                    value: '${Fmt.number(totalStores)}곳',
                    icon: Icons.storefront,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatTile(
                    label: '매장 보유 장비',
                    value: '${Fmt.number(totalAssets)}대',
                    icon: Icons.precision_manufacturing,
                  ),
                ),
              ],
            ),
          ),
          if (brands.isEmpty) const EmptyState(message: '아직 등록된 매장이 없습니다'),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            crossAxisCount: wide ? 4 : 2,
            mainAxisExtent: 154 * MediaQuery.textScalerOf(context).scale(14) / 14,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final brand in brands)
                _BrandCard(brand: brand, onTap: () => onPick(brand)),
            ],
          ),
        ],
      ),
    );
  }
}

class _BrandCard extends StatelessWidget {
  const _BrandCard({required this.brand, required this.onTap});

  final BrandSummary brand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _parseColor(brand.color) ?? theme.colorScheme.primary;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      brand.brandName,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                '${Fmt.number(brand.storeCount)}곳',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                brand.closedStoreCount > 0
                    ? '운영 ${Fmt.number(brand.openStoreCount)} · 폐점 ${Fmt.number(brand.closedStoreCount)}'
                    : '운영 ${Fmt.number(brand.openStoreCount)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.precision_manufacturing,
                      size: 14, color: theme.colorScheme.outline),
                  const SizedBox(width: 4),
                  Text('장비 ${Fmt.number(brand.assetCount)}대',
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoreList extends StatelessWidget {
  const _StoreList({
    required this.stores,
    required this.total,
    required this.onRefresh,
  });

  final List<Store> stores;
  final int total;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: stores.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('매장 $total곳', style: theme.textTheme.labelLarge),
            );
          }
          final store = stores[index - 1];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    store.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (store.isClosed) ...[
                  const SizedBox(width: 6),
                  const StatusChip(label: '폐점', color: Color(0xFF94A3B8)),
                ],
              ],
            ),
            subtitle: Text(
              [
                store.brandName,
                if (store.openDate != null) '개점 ${Fmt.date(store.openDate)}',
              ].join(' · '),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('장비 ${Fmt.number(store.assetCount)}대',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text('AS ${Fmt.number(store.ticketCount)}건',
                    style: theme.textTheme.bodySmall),
              ],
            ), const SizedBox(width: AppSpace.sm), const Icon(Icons.chevron_right)]),
            onTap: () async { await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => StoreDetailPage(storeId: store.id),
              ),
            ); if (context.mounted) onRefresh(); },
          );
        },
      ),
    );
  }
}

Color? _parseColor(String? hex) {
  if (hex == null || !hex.startsWith('#') || hex.length != 7) return null;
  final v = int.tryParse(hex.substring(1), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}
