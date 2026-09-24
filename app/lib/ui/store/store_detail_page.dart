import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/file_repository.dart';
import '../../data/store_repository.dart';
import '../../models/store.dart';
import '../async_view.dart';
import '../common/attachment_section.dart';
import '../format.dart';
import '../theme.dart';
import 'store_form_page.dart';

/// 매장 한 곳 — 무엇이 들어가 있는지.
///
/// 보유 장비를 종류별(로봇팔 / 제어박스 / 그리퍼 / 툴체인저)로 묶어 보여 준다.
/// 서버가 이미 묶어서 내려 주므로 여기서는 펼치기만 한다.
class StoreDetailPage extends StatelessWidget {
  const StoreDetailPage({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<StoreRepository>();
    final viewKey = GlobalKey<AsyncViewState<Store>>();
    Store? current;

    return Scaffold(
      appBar: AppBar(
        title: const Text('매장'),
        actions: [
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
      body: AsyncView<Store>(
        key: viewKey,
        load: () => repo.get(storeId),
        builder: (context, store, reload) {
          // 앱바의 수정 버튼이 최신 매장을 집어 갈 수 있게 들고 있는다.
          current = store;
          return _StoreBody(store: store, onRefresh: reload);
        },
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
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  store.name,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (store.isClosed)
                const StatusChip(label: '폐점', color: Color(0xFF94A3B8)),
            ],
          ),
          const SizedBox(height: 4),
          Text(store.brandName, style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: '보유 장비',
                  value: '${store.assetCount}대',
                  icon: Icons.precision_manufacturing,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: 'AS 이력',
                  value: '${store.ticketCount}건',
                  icon: Icons.build_circle_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _InfoCard(store: store),
          if (store.sets.isNotEmpty) ...[
            const SizedBox(height: 16),
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
          const SizedBox(height: 20),
          AttachmentSection(
            entityType: FileRepository.store,
            entityId: store.id,
          ),
          const SizedBox(height: 20),
          Text('보유 장비', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (store.assetGroups.isEmpty)
            const StatePlaceholder(
              icon: Icons.inventory_2_outlined,
              message: '이 매장에 등록된 장비가 없습니다.',
            )
          else
            for (final group in store.assetGroups) _AssetGroupCard(group: group),
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
      if (store.openDate != null) ('개점일', Fmt.date(store.openDate)),
      if (store.isClosed && store.closedDate != null)
        ('폐점일', Fmt.date(store.closedDate)),
      if (store.gripperType?.isNotEmpty == true)
        ('그리퍼 종류', store.gripperType!),
      if (store.note?.isNotEmpty == true) ('비고', store.note!),
    ];

    return Card(
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
  const _AssetGroupCard({required this.group});
  final StoreAssetGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _parseColor(group.color) ?? theme.colorScheme.primary;

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
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  group.categoryName,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                Text('${group.count}대', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            for (final asset in group.assets)
              Padding(
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
                        ],
                      ),
                    ),
                    if (asset.setNo > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '세트 ${asset.setNo}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    StatusChip(
                      label: asset.statusLabel,
                      color: asset.status.color,
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

Color? _parseColor(String? hex) {
  if (hex == null || !hex.startsWith('#') || hex.length != 7) return null;
  final v = int.tryParse(hex.substring(1), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}
