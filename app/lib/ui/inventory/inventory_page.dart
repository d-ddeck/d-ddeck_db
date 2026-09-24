import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/auth_repository.dart';
import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/inventory.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';
import 'asset_form_page.dart';

/// 재고관리: asset list, location tree, and the move dialog that is the single
/// write path for location / holder / status.
class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

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
            Tab(text: '자산', icon: Icon(Icons.inventory_2_outlined, size: 18)),
            Tab(text: '위치', icon: Icon(Icons.account_tree_outlined, size: 18)),
            Tab(text: '현황', icon: Icon(Icons.pie_chart_outline, size: 18)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: const [
              _AssetListTab(),
              _LocationTreeTab(),
              _InventorySummaryTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class _AssetListTab extends StatefulWidget {
  const _AssetListTab();

  @override
  State<_AssetListTab> createState() => _AssetListTabState();
}

class _AssetListTabState extends State<_AssetListTab> {
  final _search = TextEditingController();
  final _viewKey = GlobalKey<AsyncViewState<PagedList<Asset>>>();

  String? _query;
  AssetStatus? _status;
  bool _belowMinOnly = false;

  /// 자산 분류(로봇팔 / 제어박스 / 전동 그리퍼 / …). 코드 마스터에서 읽으므로
  /// 화면이 종류를 하드코딩하지 않는다 - 관리 화면에서 항목을 더하면 여기에
  /// 바로 탭이 하나 는다.
  String? _categoryId;
  List<CodeItem> _categories = const [];

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    try {
      final group = await context.read<AdminRepository>().codeGroup('ASSET_CATEGORY');
      if (!mounted) return;
      setState(() => _categories = group.items.where((i) => i.isActive).toList());
    } catch (_) {
      // 분류를 못 읽어도 목록 자체는 보여야 한다. 필터만 빠진다.
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() => _viewKey.currentState?.reload();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<InventoryRepository>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        hintText: '품명 / 자산번호 / 시리얼 / 바코드 검색',
                        prefixIcon: Icon(Icons.search, size: 20),
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (v) => setState(() {
                        _query = v.trim().isEmpty ? null : v.trim();
                        _refresh();
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () async {
                      final added = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => const AssetFormPage()),
                      );
                      if (added == true) _refresh();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('등록'),
                  ),
                ],
              ),
              if (_categories.isNotEmpty) ...[
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('전체 종류'),
                        selected: _categoryId == null,
                        onSelected: (_) => setState(() {
                          _categoryId = null;
                          _refresh();
                        }),
                      ),
                      for (final c in _categories) ...[
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: Text(c.name),
                          selected: _categoryId == c.id,
                          onSelected: (_) => setState(() {
                            _categoryId = c.id;
                            _refresh();
                          }),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('안전재고 미만'),
                      selected: _belowMinOnly,
                      onSelected: (v) => setState(() {
                        _belowMinOnly = v;
                        _refresh();
                      }),
                    ),
                    const SizedBox(width: 12),
                    ChoiceChip(
                      label: const Text('전체'),
                      selected: _status == null,
                      onSelected: (_) => setState(() {
                        _status = null;
                        _refresh();
                      }),
                    ),
                    for (final s in AssetStatus.values) ...[
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: Text(s.label),
                        selected: _status == s,
                        selectedColor: s.color.withValues(alpha: 0.2),
                        onSelected: (_) => setState(() {
                          _status = s;
                          _refresh();
                        }),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: AsyncView<PagedList<Asset>>(
            key: _viewKey,
            load: () => repo.list(
              query: _query,
              status: _status,
              categoryId: _categoryId,
              belowMinOnly: _belowMinOnly,
              size: 50,
            ),
            emptyCheck: (p) => p.isEmpty,
            emptyMessage: '조건에 맞는 자산이 없습니다.',
            emptyIcon: Icons.inventory_2_outlined,
            builder: (context, page, reload) => ListView.separated(
              itemCount: page.items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _AssetTile(
                asset: page.items[i],
                onChanged: reload,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({required this.asset, required this.onChanged});

  final Asset asset;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AssetDetailPage(assetId: asset.id),
        ),
      ).then((_) => onChanged()),
      title: Row(
        children: [
          StatusChip(
            label: asset.status.label,
            color: asset.status.color,
            dense: true,
          ),
          if (asset.isBelowMin) ...[
            const SizedBox(width: 4),
            const StatusChip(
              label: '재고부족',
              color: Color(0xFFF59E0B),
              icon: Icons.warning_amber_rounded,
              dense: true,
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              asset.name,
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
          '${asset.assetNo}'
          '${asset.location != null ? ' · ${asset.location!.display}' : ''}'
          '${asset.holder != null ? ' · ${asset.holder!.fullName}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      ),
      trailing: Text(
        '${Fmt.number(asset.quantity)} ${asset.unit}',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class AssetDetailPage extends StatefulWidget {
  const AssetDetailPage({super.key, required this.assetId});
  final String assetId;

  @override
  State<AssetDetailPage> createState() => _AssetDetailPageState();
}

class _AssetDetailPageState extends State<AssetDetailPage> {
  final _viewKey = GlobalKey<AsyncViewState<(Asset, PagedList<AssetMovement>)>>();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<InventoryRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('자산 상세')),
      body: AsyncView<(Asset, PagedList<AssetMovement>)>(
        key: _viewKey,
        load: () async {
          final results = await Future.wait([
            repo.get(widget.assetId),
            repo.movements(widget.assetId),
          ]);
          return (results[0] as Asset, results[1] as PagedList<AssetMovement>);
        },
        builder: (context, data, reload) {
          final (asset, movements) = data;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  StatusChip(
                      label: asset.status.label, color: asset.status.color),
                  if (asset.isBelowMin) ...[
                    const SizedBox(width: 6),
                    const StatusChip(
                        label: '안전재고 미만', color: Color(0xFFF59E0B)),
                  ],
                  if (asset.warrantyExpired) ...[
                    const SizedBox(width: 6),
                    const StatusChip(
                        label: '보증 만료', color: Color(0xFF94A3B8)),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                asset.name,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                asset.assetNo,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline),
              ),
              const SizedBox(height: 16),
              _KeyValueCard(
                title: '자산 정보',
                rows: [
                  ('분류', asset.category?.name ?? '-'),
                  ('제조사', asset.manufacturer ?? '-'),
                  ('모델', asset.modelName ?? '-'),
                  ('시리얼', asset.serialNo ?? '-'),
                  ('수량', '${Fmt.number(asset.quantity)} ${asset.unit}'),
                  if (asset.minQuantity != null)
                    ('안전재고', Fmt.number(asset.minQuantity)),
                  ('구입일', Fmt.date(asset.purchaseDate)),
                  ('구입가', Fmt.money(asset.purchasePrice)),
                  ('보증 만료', Fmt.date(asset.warrantyUntil)),
                ],
              ),
              const SizedBox(height: 12),
              _KeyValueCard(
                title: '현재 위치',
                rows: [
                  ('위치', asset.location?.display ?? '미지정'),
                  ('보관 책임자', asset.holder?.display ?? '-'),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _showMoveDialog(asset, reload),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('위치 / 상태 변경'),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('이동 이력 (${movements.total}건)',
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      for (final m in movements.items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(m.movementType.icon, size: 15),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      m.movementType.label,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    Text(
                                      '${Fmt.dateTime(m.movedAt)}'
                                      '${m.reason != null ? ' · ${m.reason}' : ''}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  /// 위치 · 매장 · 상태를 한 화면에서 바꾼다.
  ///
  /// PATCH 로는 이 셋을 못 바꾼다 - /move 만 이력을 남기기 때문이다. 그래서
  /// "어디로 보낼지"(창고 / 매장 / 사람)와 "무슨 상태가 되는지"를 같이 받는다.
  Future<void> _showMoveDialog(Asset asset, VoidCallback reload) async {
    final repo = context.read<InventoryRepository>();
    final authRepo = context.read<AuthRepository>();
    final storeRepo = context.read<StoreRepository>();
    final adminRepo = context.read<AdminRepository>();

    final locations = await repo.locations();
    final members = (await authRepo.directory(size: 100)).items;
    final stores = (await storeRepo.list(size: 300, includeClosed: true)).items;
    List<CodeItem> statuses = const [];
    try {
      statuses = (await adminRepo.codeGroup('ASSET_STATUS'))
          .items
          .where((i) => i.isActive)
          .toList();
    } catch (_) {
      // 세부 상태 목록이 없어도 나머지는 바꿀 수 있어야 한다.
    }
    if (!mounted) return;

    var type = MovementType.move;
    var target = asset.storeId != null ? _MoveTarget.store : _MoveTarget.location;
    String? locationId = asset.locationId;
    String? storeId = asset.storeId;
    String? holderId = asset.holderId;
    String? statusItemId = asset.statusItem?.id;
    AssetStatus status = asset.status;
    final reason = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('위치 / 상태 변경'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<MovementType>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: '변경 유형'),
                    isExpanded: true,
                    items: [
                      for (final t in MovementType.values)
                        DropdownMenuItem(value: t, child: Text(t.label)),
                    ],
                    onChanged: (v) => setInner(() => type = v ?? type),
                  ),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('어디로 보내나요?',
                        style: Theme.of(ctx).textTheme.labelLarge),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<_MoveTarget>(
                    segments: const [
                      ButtonSegment(
                        value: _MoveTarget.location,
                        label: Text('창고'),
                        icon: Icon(Icons.warehouse_outlined),
                      ),
                      ButtonSegment(
                        value: _MoveTarget.store,
                        label: Text('매장'),
                        icon: Icon(Icons.storefront_outlined),
                      ),
                      ButtonSegment(
                        value: _MoveTarget.person,
                        label: Text('사람'),
                        icon: Icon(Icons.person_outline),
                      ),
                    ],
                    selected: {target},
                    onSelectionChanged: (v) =>
                        setInner(() => target = v.first),
                  ),
                  const SizedBox(height: 12),
                  if (target == _MoveTarget.location)
                    DropdownButtonFormField<String>(
                      initialValue: locationId,
                      decoration: const InputDecoration(labelText: '이동할 위치'),
                      isExpanded: true,
                      items: [
                        for (final l in locations)
                          DropdownMenuItem(
                            value: l.id,
                            child: Text(l.display,
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) => setInner(() => locationId = v),
                    )
                  else if (target == _MoveTarget.store)
                    DropdownButtonFormField<String>(
                      initialValue: storeId,
                      decoration: const InputDecoration(labelText: '이동할 매장'),
                      isExpanded: true,
                      items: [
                        for (final st in stores)
                          DropdownMenuItem(
                            value: st.id,
                            child: Text(
                              '${st.brandName} · ${st.name}'
                              '${st.isClosed ? ' (폐점)' : ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setInner(() => storeId = v),
                    )
                  else
                    DropdownButtonFormField<String>(
                      initialValue: holderId,
                      decoration: const InputDecoration(labelText: '불출 대상자'),
                      isExpanded: true,
                      items: [
                        for (final m in members)
                          DropdownMenuItem(value: m.id, child: Text(m.display)),
                      ],
                      onChanged: (v) => setInner(() => holderId = v),
                    ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<AssetStatus>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: '상태'),
                    isExpanded: true,
                    items: [
                      for (final st in AssetStatus.values)
                        DropdownMenuItem(value: st, child: Text(st.label)),
                    ],
                    onChanged: (v) => setInner(() => status = v ?? status),
                  ),
                  if (statuses.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: statusItemId,
                      decoration: const InputDecoration(
                        labelText: '세부 상태',
                        helperText: '설치 / 렌탈 중 / AS 대기 / 회수 …',
                      ),
                      isExpanded: true,
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('바꾸지 않음')),
                        for (final c in statuses)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => setInner(() => statusItemId = v),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: reason,
                    decoration: const InputDecoration(labelText: '사유'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('변경'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await runGuarded(
      context,
      () => repo.move(
        asset.id,
        type: type,
        toLocationId: target == _MoveTarget.location ? locationId : null,
        toStoreId: target == _MoveTarget.store ? storeId : null,
        toHolderId: target == _MoveTarget.person ? holderId : null,
        // 창고나 사람에게 보내면 매장 연결을 끊는다. 매장에 있으면서 동시에
        // 창고에 있을 수는 없다.
        clearStore: target != _MoveTarget.store,
        toStatusItemId: statusItemId,
        toStatus: status,
        reason: reason.text,
      ),
      successMessage: '${type.label} 처리되었습니다.',
    );
    if (ok) reload();
  }
}

/// 이동 대상. 자산은 우리 위치에 있거나, 매장에 나가 있거나, 누군가 들고 있다.
enum _MoveTarget { location, store, person }

class _LocationTreeTab extends StatelessWidget {
  const _LocationTreeTab();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<InventoryRepository>();
    return AsyncView<List<StorageLocation>>(
      load: repo.tree,
      emptyCheck: (l) => l.isEmpty,
      emptyMessage: '등록된 위치가 없습니다.',
      emptyIcon: Icons.account_tree_outlined,
      builder: (context, roots, reload) {
        final rows = StorageLocation.flatten(roots);
        return ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final (node, depth) = rows[i];
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.only(left: 16.0 + depth * 20, right: 16),
              leading: Icon(node.type.icon, size: 18),
              title: Text(node.name, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                '${node.code} · ${node.type.label}',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: node.assetCount > 0
                  ? StatusChip(
                      label: '${node.assetCount}건',
                      color: Theme.of(context).colorScheme.primary,
                      dense: true,
                    )
                  : null,
            );
          },
        );
      },
    );
  }
}

class _InventorySummaryTab extends StatelessWidget {
  const _InventorySummaryTab();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<InventoryRepository>();
    return AsyncView<InventorySummary>(
      load: repo.summary,
      builder: (context, s, reload) {
        final wide = AppTheme.isWide(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GridView.count(
              crossAxisCount: wide ? 4 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: wide ? 1.9 : 1.5,
              children: [
                StatTile(
                  label: '총 자산',
                  value: '${s.totalAssets}건',
                  hint: '수량 ${Fmt.number(s.totalQuantity)}',
                  icon: Icons.inventory_2_outlined,
                ),
                StatTile(
                  label: '자산 평가액',
                  value: Fmt.money(s.totalValue),
                  icon: Icons.payments_outlined,
                  color: const Color(0xFF8B5CF6),
                ),
                StatTile(
                  label: '안전재고 미만',
                  value: '${s.belowMinCount}건',
                  icon: Icons.warning_amber_rounded,
                  color: s.belowMinCount > 0 ? const Color(0xFFF59E0B) : null,
                ),
                StatTile(
                  label: '보증 만료 임박',
                  value: '${s.warrantyExpiringCount}건',
                  hint: '30일 이내',
                  icon: Icons.verified_outlined,
                ),
              ],
            ),
            const SizedBox(height: 18),
            _CountCard(title: '상태별', buckets: s.byStatus),
            const SizedBox(height: 12),
            _CountCard(title: '분류별', buckets: s.byCategory),
            const SizedBox(height: 12),
            _CountCard(title: '위치별', buckets: s.byLocation, shortenPath: true),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

class _CountCard extends StatelessWidget {
  const _CountCard({
    required this.title,
    required this.buckets,
    this.shortenPath = false,
  });

  final String title;
  final List<CountBucket> buckets;
  final bool shortenPath;

  @override
  Widget build(BuildContext context) {
    final max = buckets.fold<int>(1, (a, b) => b.count > a ? b.count : a);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (buckets.isEmpty)
              const Text('데이터가 없습니다.', style: TextStyle(fontSize: 12))
            else
              for (final b in buckets)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 96,
                        child: Text(
                          shortenPath ? b.label.split(' > ').last : b.label,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: b.count / max,
                            minHeight: 6,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${b.count}건',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _KeyValueCard extends StatelessWidget {
  const _KeyValueCard({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 78,
                      child: Text(label,
                          style:
                              TextStyle(fontSize: 12, color: scheme.outline)),
                    ),
                    Expanded(
                      child: Text(value, style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
