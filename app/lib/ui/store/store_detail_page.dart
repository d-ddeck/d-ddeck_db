import '../../core/colors.dart';
import '../inventory/delivery_compare_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/file_repository.dart';
import '../../data/store_repository.dart';
import '../../models/store.dart';
import '../../models/service.dart';
import '../../state/auth_state.dart';
import '../inventory/asset_actions.dart';
import '../inventory/inventory_page.dart';
import '../service/service_detail_page.dart';
import 'store_equipment_page.dart';
import '../async_view.dart';
import '../common/attachment_section.dart';
import '../format.dart';
import '../theme.dart';
import '../service/service_form_page.dart';
import 'store_form_page.dart';

/// 매장 한 곳 — 무엇이 들어가 있는지.
///
/// 보유 장비를 종류별(로봇팔 / 제어박스 / 그리퍼 / 툴체인저)로 묶어 보여 준다.
/// 서버가 이미 묶어서 내려 주므로 여기서는 펼치기만 한다.
class StoreDetailPage extends StatefulWidget {
  const StoreDetailPage({super.key, required this.storeId});

  final String storeId;

  @override
  State<StoreDetailPage> createState() => _StoreDetailPageState();
}

class _StoreDetailPageState extends State<StoreDetailPage> {
  String get storeId => widget.storeId;
  final viewKey = GlobalKey<AsyncViewState<Store>>();
  Store? current;
  @override
  Widget build(BuildContext context) {
    final repo = context.read<StoreRepository>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('매장'),
        actions: [
          if (context.watch<AuthState>().isAdmin)
            IconButton(
              tooltip: '수정',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                if (current == null) return;
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => StoreFormPage(store: current),
                  ),
                );
                if (saved == true) viewKey.currentState?.reload();
              },
            ),
        ],
      ),
      body: PageBody(
        child: AsyncView<Store>(
          key: viewKey,
          load: () => guardedLoad(context, () => repo.get(storeId)),
          builder: (context, store, reload) {
            // 앱바의 수정 버튼이 최신 매장을 집어 갈 수 있게 들고 있는다.
            current = store;
            return _StoreBody(store: store, onRefresh: reload);
          },
        ),
      ),
    );
  }
}

class _StoreBody extends StatelessWidget {
  const _StoreBody({required this.store, required this.onRefresh});

  final Store store;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = <Widget>[
      _InfoCard(store: store),

      const SizedBox(height: AppSpace.md),
      SectionCard(
        title: '보유 장비 (세트)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (context.select<AuthState, bool>((s) => s.isAdmin))
              OutlinedButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text('장비 설정'),
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StoreEquipmentPage(storeId: store.id),
                    ),
                  );
                  if (context.mounted) onRefresh();
                },
              ),
            if (store.sets.isNotEmpty) ...[
              const SizedBox(height: AppSpace.lg),
              Text('납품 세트', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final set in store.sets)
                    Chip(
                      avatar: const Icon(Icons.widgets_outlined, size: 18),
                      label: Text(set.label),
                    ),
                ],
              ),
            ],

            const SizedBox(height: 8),
            if (store.assetGroups.isEmpty)
              const StatePlaceholder(
                icon: Icons.inventory_2_outlined,
                message: '아직 등록된 장비가 없습니다',
              )
            else
              for (final number
                  in (store.assetGroups
                      .expand((g) => g.assets)
                      .map((a) => a.setNo)
                      .toSet()
                      .toList()
                    ..sort())) ...[
                Text(
                  store.sets
                          .where((s) => s.setNo == number)
                          .firstOrNull
                          ?.label ??
                      (number == 0 ? '세트 미지정' : '세트 $number'),
                  style: theme.textTheme.titleSmall,
                ),
                const FormGap(),
                CardStack(
                  children: [
                    for (final group in store.assetGroups)
                      if (group.assets.any((a) => a.setNo == number))
                        _AssetGroupCard(
                          group: StoreAssetGroup(
                            categoryId: group.categoryId,
                            categoryName: group.categoryName,
                            color: group.color,
                            count: group.assets
                                .where((a) => a.setNo == number)
                                .length,
                            assets: group.assets
                                .where((a) => a.setNo == number)
                                .toList(),
                          ),
                          onRefresh: onRefresh,
                        ),
                  ],
                ),
                const FormGap(),
              ],
            const SizedBox(height: AppSpace.lg),
          ],
        ),
      ),
    ];
    final right = <Widget>[
      SectionCard(
        title: '구분별 발생',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (store.categoryCounts.isEmpty)
              const EmptyState(message: '아직 등록된 발생 기록이 없습니다'),
            for (final c in store.categoryCounts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${c.label} · ${Fmt.number(c.count)}건'),
                    LinearProgressIndicator(
                      value:
                          c.count /
                          store.categoryCounts.fold<int>(
                            1,
                            (n, row) => row.count > n ? row.count : n,
                          ),
                      color: tryParseHexColor(c.color),
                      minHeight: 10,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.md),
      SectionCard(
        title: '미회수 렌탈',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (store.unreturnedRentals.isEmpty)
              const EmptyState(message: '아직 등록된 미회수 렌탈이 없습니다'),
            for (final rental in store.unreturnedRentals)
              ListTile(
                contentPadding: EdgeInsets.zero,
                trailing: const Icon(Icons.chevron_right),
                title: Text('${rental.ticketNo} · ${rental.serials ?? '-'}'),
                subtitle: Text(
                  '${rental.rentalType ?? ''} · ${Fmt.date(rental.dueDate)} · ${Fmt.dday(rental.dday)}',
                ),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ServiceDetailPage(ticketId: rental.ticketId),
                    ),
                  );
                  if (context.mounted) onRefresh();
                },
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.md),
      SectionCard(
        title: '서비스 이력 (미종결 ${Fmt.number(store.openTicketCount)}건)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (store.recentTickets.isEmpty)
              const EmptyState(message: '아직 등록된 서비스 이력이 없습니다'),
            for (final ticket in store.recentTickets)
              ListTile(
                contentPadding: EdgeInsets.zero,
                trailing: const Icon(Icons.chevron_right),
                title: Text(
                  '${ticket.ticketNo} · ${ServiceStatus.parse(ticket.status).label}',
                ),
                subtitle: Text(
                  '${Fmt.date(ticket.receivedAt)} · ${ticket.causeLabels.join(' · ')}',
                ),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ServiceDetailPage(ticketId: ticket.id),
                    ),
                  );
                  if (context.mounted) onRefresh();
                },
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.lg),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('이 매장 기록 추가'),
          onPressed: () async {
            final saved = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) => ServiceFormPage(
                  initialStoreId: store.id,
                  initialBrandId: store.brandId,
                ),
              ),
            );
            if (saved == true && context.mounted) onRefresh();
          },
        ),
      ),
    ];
    Widget tab(String key, List<Widget> children) => ListView(
      key: PageStorageKey('store-${store.id}-$key'),
      padding: const EdgeInsets.only(top: 16),
      children: children,
    );
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(store.name, style: theme.textTheme.headlineSmall),
          Wrap(
            runSpacing: 12,
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(store.brandName),
              StatusChip(
                label: store.isClosed
                    ? '미운영'
                    : store.isActive
                    ? '운영 중'
                    : '비활성',
                icon: store.isClosed ? Icons.store_outlined : Icons.store,
                color: store.isClosed
                    ? AppColors.muted(context)
                    : theme.colorScheme.primary,
              ),
              Text('장비 ${store.assetCount}대 · 미종결 ${store.openTicketCount}건'),
            ],
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '기본 정보'),
              Tab(text: '장비'),
              Tab(text: '서비스·렌탈'),
              Tab(text: '사진·첨부'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                tab('info', [left.first]),
                tab('assets', [
                  ...left.skip(1),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DeliveryComparePage(storeId: store.id),
                      ),
                    ),
                    icon: const Icon(Icons.compare_arrows),
                    label: const Text('출고 대조'),
                  ),
                ]),
                tab('service', right),
                tab('photos', [
                  for (final category in {
                    'shop': '가게 사진',
                    'robot': '로봇 설치 사진',
                    'ctrl': '제어박스 설치 사진',
                    'panel': '조작부 설치 사진',
                    'serial': '장비 시리얼 넘버 사진',
                  }.entries)
                    ExpansionTile(
                      title: Text(category.value),
                      children: [
                        AttachmentSection(
                          entityType: 'store',
                          entityId: store.id,
                          photoCategory: category.key,
                        ),
                      ],
                    ),
                  AttachmentSection(
                    entityType: FileRepository.store,
                    entityId: store.id,
                    photoCategory: 'general',
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('브랜드', store.brandName),
      (
        '매장 담당자',
        store.contactName?.isNotEmpty == true ? store.contactName! : '미등록',
      ),
      (
        '연락처',
        store.contactPhone?.isNotEmpty == true ? store.contactPhone! : '미등록',
      ),
      ('주소', store.address?.isNotEmpty == true ? store.address! : '미등록'),
      ('미운영 여부', store.isClosed ? '미운영' : '운영'),
      ('설치일', Fmt.date(store.installDate)),
      if (store.openDate != null) ('개점일', Fmt.date(store.openDate)),
      if (store.isClosed && store.closedDate != null)
        ('미운영일', Fmt.date(store.closedDate)),
      if (store.gripperType?.isNotEmpty == true) ('그리퍼 종류', store.gripperType!),
      if (store.note?.isNotEmpty == true) ('비고', store.note!),
    ];

    return SectionCard(
      title: '기본 정보',
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 84,
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(child: Text(value)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AssetGroupCard extends StatelessWidget {
  const _AssetGroupCard({required this.group, required this.onRefresh});
  final StoreAssetGroup group;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tryParseHexColor(group.color) ?? theme.colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
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
                Text(
                  group.categoryName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${Fmt.number(group.count)}대',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final asset in group.assets)
              InkWell(
                onTap: () async {
                  await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AssetDetailPage(assetId: asset.id),
                    ),
                  );
                  if (context.mounted) onRefresh();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              asset.serialNo?.isNotEmpty == true
                                  ? asset.serialNo!
                                  : asset.assetNo,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (asset.modelName?.isNotEmpty == true)
                              Text(
                                asset.modelName!,
                                style: theme.textTheme.bodySmall,
                              ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                if (asset.setNo > 0)
                                  Text(
                                    '세트 ${asset.setNo}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                StatusChip(
                                  label: asset.statusLabel,
                                  color: asset.status.color,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      AssetActionsMenu(
                        key: ValueKey(asset.id),
                        assetId: asset.id,
                        label:
                            '${asset.name} S/N ${asset.serialNo ?? asset.assetNo}',
                        atStore: true,
                        onChanged: onRefresh,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
