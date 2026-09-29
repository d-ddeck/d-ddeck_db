import '../../state/auth_state.dart';
import '../../services/filter_memory.dart';
import '../../core/colors.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/store_repository.dart';
import '../equipment/equipment_page.dart';
import '../../models/store.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';
import 'store_detail_page.dart';
import 'store_form_page.dart';

/// 매장 화면.
///
/// 브랜드 -> 매장 -> 보유 장비의 세 단계다. 구 서버가 이 순서로 읽혔고, 팀이
/// "바른치킨 강남역점에 뭐가 들어가 있지"를 그 순서로 묻기 때문이다.
///
/// 첫 화면은 브랜드 카드다. 매장 73곳을 한 줄로 늘어놓으면 찾을 수가 없다.
class StoreTab extends StatefulWidget {
  const StoreTab({
    super.key,
    this.initialBrandId,
    this.revision = 0,
    this.onChanged,
  });
  final VoidCallback? onChanged;
  final String? initialBrandId;
  final int revision;

  @override
  State<StoreTab> createState() => StoreTabState();
}

class StoreTabState extends State<StoreTab> {
  final _searchCtl = TextEditingController();
  String? _brandId;
  String _brandName = '';
  String _query = '';
  bool _includeClosed = false, _includeInactive = false, _descending = false;
  String _sort = "name";

  int _revision = 0;
  List<BrandSummary> _brands = [];

  String? _filterKey;
  bool _filtersReady = false;
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_filtersReady && _filterKey != null) {
      FilterMemory.save(_filterKey!, {
        'brand': _brandId,
        'brand_name': _brandName,
        'q': _query,
        'closed': _includeClosed,
        'inactive': _includeInactive,
        'sort': _sort,
        'descending': _descending,
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final auth = context.read<AuthState>();
      if (auth.user == null) return;
      _filterKey = FilterMemory.key(auth.serverUrl, auth.user!.id, 'stores');
      final saved = widget.initialBrandId == null
          ? await FilterMemory.load(_filterKey!)
          : <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        if (saved.isNotEmpty) {
          _brandId = saved['brand'] as String?;
          _brandName = saved['brand_name'] as String? ?? '';
          _query = saved['q'] as String? ?? '';
          _searchCtl.text = _query;
          _includeClosed = saved['closed'] == true;
          _includeInactive = saved['inactive'] == true;
          _sort = saved['sort'] as String? ?? 'name';
          _descending = saved['descending'] == true;
        }
        _filtersReady = true;
      });
    });
    _brandId = widget.initialBrandId == '-' ? null : widget.initialBrandId;
    _brandName = widget.initialBrandId == '-'
        ? '미지정'
        : widget.initialBrandId == null
        ? ''
        : '선택한 브랜드';
  }

  @override
  void didUpdateWidget(covariant StoreTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) _revision++;
  }

  void selectBrand(String? id) => setState(() {
    _brandId = id == '-' ? null : id;
    _brandName = id == '-'
        ? '미지정'
        : id == null
        ? ''
        : _brands.where((b) => b.brandId == id).firstOrNull?.brandName ??
              '선택한 브랜드';
    _query = '';
    _searchCtl.clear();
    _includeClosed = false;
  });

  bool backToBrands() {
    if (_brandId == null &&
        _brandName.isEmpty &&
        _query.isEmpty &&
        !_includeClosed &&
        !_includeInactive) {
      return false;
    }
    setState(() {
      _brandId = null;
      _brandName = '';
      _query = '';
      _searchCtl.clear();
      _includeClosed = false;
      _includeInactive = false;
    });
    return true;
  }

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
    if (_brandId == null &&
        _brandName.isEmpty &&
        _query.isEmpty &&
        !_includeClosed &&
        !_includeInactive) {
      return PageBody(
        child: AsyncView<List<BrandSummary>>(
          key: ValueKey('brands:$_revision'),
          load: () => guardedLoad(context, repo.brands),
          builder: (context, data, reload) {
            _brands = data;
            return _BrandGrid(
              brands: data,
              onPick: (brand) => EquipmentPage.open(
                context,
                tab: EquipmentTab.stores,
                brandId: brand.brandId ?? '-',
              ),
              searchField: _buildSearch(),
              onRefresh: reload,
            );
          },
        ),
      );
    }

    return PageBody(
      child: Column(
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
              key: ValueKey(
                '$_brandId|$_brandName|$_query|$_includeClosed|$_includeInactive|$_sort|$_descending|$_revision',
              ),
              load: () => guardedLoad(context, () async {
                final items = <Store>[];
                var pageNo = 1;
                while (true) {
                  final page = await repo.list(
                    page: pageNo++,
                    brandId: _brandId,
                    query: _query.isEmpty ? null : _query,
                    includeClosed: _includeClosed,
                    includeInactive: _includeInactive,
                    sort: _sort,
                    descending: _descending,
                    size: 200,
                  );
                  items.addAll(
                    page.items.where(
                      (s) =>
                          _brandId != null ||
                          _brandName.isEmpty ||
                          s.brandId == null,
                    ),
                  );
                  if (!page.hasMore) break;
                }
                if (_brandId != null && items.isNotEmpty) {
                  _brandName = items.first.brandName;
                }
                return PagedStores(items, items.length);
              }),
              emptyCheck: (d) => d.items.isEmpty,
              emptyMessage: '아직 등록된 매장이 없습니다',
              builder: (context, data, reload) => _StoreList(
                stores: data.items,
                total: data.total,
                onRefresh: () {
                  reload();
                  widget.onChanged?.call();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addStore() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const StoreFormPage()));
    if (saved == true && mounted) {
      setState(() => _revision++);
      widget.onChanged?.call();
    }
  }

  Widget _buildSearch() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _addStore,
          icon: const Icon(Icons.add),
          label: const Text('매장 등록'),
        ),
      ),
      FilterBar(
        appliedFilters: [
          if (_query.isNotEmpty) '검색: $_query',
          if (_includeClosed) '폐점 포함',
          if (_brandName.isNotEmpty) _brandName,
        ],
        onReset: () => setState(() {
          _query = '';
          _searchCtl.clear();
          _includeClosed = false;
          _brandId = null;
          _brandName = '';
        }),
        children: [
          SizedBox(
            width: AppTheme.isWide(context) ? 360 : double.infinity,
            child: _searchBox(),
          ),
          FilterChip(
            label: const Text('비활성 포함'),
            selected: _includeInactive,
            onSelected: (v) => setState(() => _includeInactive = v),
          ),
          DropdownButton<String>(
            value: _sort,
            items: [
              for (final item in {
                'name': '매장명',
                'open_date': '개점일',
                'created_at': '등록일',
                'ticket_count': '대응 건수',
                'asset_count': '설치 장비',
                'open_ticket_count': '미종결 건수',
                'last_ticket_at': '최근 대응일',
              }.entries)
                DropdownMenuItem(value: item.key, child: Text(item.value)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _sort = v);
            },
          ),
          IconButton(
            tooltip: _descending ? '내림차순' : '오름차순',
            onPressed: () => setState(() => _descending = !_descending),
            icon: Icon(_descending ? Icons.arrow_downward : Icons.arrow_upward),
          ),
          FilterChip(
            label: const Text('폐점 포함'),
            selected: _includeClosed,
            onSelected: (v) => setState(() => _includeClosed = v),
          ),
        ],
      ),
    ],
  );

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

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          searchField,
          if (brands.isEmpty) const EmptyState(message: '아직 등록된 매장이 없습니다'),
          const SizedBox(height: 16),
          SectionCard(
            title: '최근 대응 매장',
            child: AsyncView<List<Store>>(
              load: () async => (await context.read<StoreRepository>().list(
                sort: 'last_ticket_at',
                descending: true,
                size: 5,
              )).items,
              builder: (context, stores, reload) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (stores.isEmpty) const Text('매장을 등록하면 최근 대응 순서로 표시됩니다.'),
                  for (final store in stores)
                    ActionChip(
                      label: Text(
                        '${store.name} · 미종결 ${store.openTicketCount}',
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => StoreDetailPage(storeId: store.id),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.md,
              children: [
                for (final brand in brands)
                  SizedBox(
                    width:
                        (constraints.maxWidth -
                            AppSpace.md *
                                ((wide
                                        ? brands.length.clamp(1, 4)
                                        : constraints.maxWidth < 500
                                        ? 1
                                        : 2) -
                                    1)) /
                        (wide
                            ? brands.length.clamp(1, 4)
                            : constraints.maxWidth < 500
                            ? 1
                            : 2),
                    child: _BrandCard(brand: brand, onTap: () => onPick(brand)),
                  ),
              ],
            ),
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
    final color = tryParseHexColor(brand.color) ?? theme.colorScheme.primary;

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
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                '운영 ${Fmt.number(brand.openStoreCount)}',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
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
              child: Text('매장 $total', style: theme.textTheme.labelLarge),
            );
          }
          final store = stores[index - 1];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    '${store.name} · ${store.brandName}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (store.isClosed) ...[
                  const SizedBox(width: 6),
                  StatusChip(label: '폐점', color: AppColors.muted(context)),
                ],
              ],
            ),
            subtitle: Text(
              '설치 ${Fmt.number(store.assetCount)}대 · 대응 ${store.ticketCount}건 · 미종결 ${Fmt.number(store.openTicketCount)}건\n개점 ${Fmt.date(store.openDate)} · 최근 대응 ${Fmt.date(store.lastTicketAt)}${store.isActive ? '' : ' · 비활성'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => StoreDetailPage(storeId: store.id),
                ),
              );
              if (context.mounted) onRefresh();
            },
          );
        },
      ),
    );
  }
}
