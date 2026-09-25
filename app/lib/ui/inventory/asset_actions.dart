import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../models/inventory.dart';
import '../../state/auth_state.dart';
import 'asset_destination.dart';

enum AssetAction { move, warehouse, delete }

Future<bool> performAssetAction(BuildContext context, AssetAction action,
    {required String assetId, required String label}) async {
  if (action == AssetAction.delete && !context.read<AuthState>().isManager) return false;
  final repo = context.read<InventoryRepository>();
  final admin = context.read<AdminRepository>();
  try {
    if (action == AssetAction.move) {
      if (!await showAssetMoveDialog(context, [assetId])) return false;
    } else {
      final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: Text(action == AssetAction.delete ? '장비 삭제' : '매장에서 빼기 → 창고'),
        content: SingleChildScrollView(child: Text(action == AssetAction.delete
          ? '$label\n\n재고에서 완전히 지웁니다. 이력도 함께 사라집니다'
          : '$label 을 창고로 옮깁니다')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: Text(action == AssetAction.delete ? '삭제' : '창고로 이동'))],
      ));
      if (confirmed != true || !context.mounted) return false;
      if (action == AssetAction.delete) {
        if (!context.read<AuthState>().isManager) return false;
        await repo.delete(assetId);
      } else {
        final statuses = await admin.codeGroup('ASSET_STATUS');
        final warehouse = statuses.selectable.where((s) =>
          s.extra['rule'] == 'clear' && s.extra['place'] == '창고').firstOrNull;
        if (!context.mounted) return false;
        if (warehouse == null) {
          inventoryMessage(context, '사용 가능한 창고 상태가 없습니다.');
          return false;
        }
        await repo.move(assetId, type: MovementType.move, toStatusItemId: warehouse.id);
      }
    }
    if (context.mounted) {
      inventoryMessage(context, switch (action) {
        AssetAction.move => '이동 / 상태를 변경했습니다.',
        AssetAction.warehouse => '장비를 창고로 옮겼습니다.',
        AssetAction.delete => '장비를 삭제했습니다.',
      });
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) inventoryMessage(context, e.message);
    return false;
  }
}

class AssetActionsMenu extends StatefulWidget {
  const AssetActionsMenu({super.key, required this.assetId, required this.label,
    required this.onChanged, this.atStore = false});
  final String assetId, label;
  final VoidCallback onChanged;
  final bool atStore;
  @override
  State<AssetActionsMenu> createState() => _AssetActionsMenuState();
}

class _AssetActionsMenuState extends State<AssetActionsMenu> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final isManager = context.watch<AuthState>().isManager;
    return PopupMenuButton<AssetAction>(
      tooltip: '장비 작업', enabled: !_busy, icon: const Icon(Icons.more_vert),
      itemBuilder: (_) => [
        const PopupMenuItem(value: AssetAction.move, child: Text('이동 / 상태 변경')),
        if (widget.atStore) const PopupMenuItem(value: AssetAction.warehouse, child: Text('매장에서 빼기 → 창고')),
        if (isManager) const PopupMenuItem(value: AssetAction.delete, child: Text('삭제')),
      ],
      onSelected: (action) async {
        if (_busy) return;
        setState(() => _busy = true);
        try {
          if (await performAssetAction(context, action, assetId: widget.assetId, label: widget.label) && mounted) {
            widget.onChanged();
          }
        } finally { if (mounted) setState(() => _busy = false); }
      },
    );
  }
}

class AssetDeleteButton extends StatefulWidget {
  const AssetDeleteButton({super.key, required this.assetId});
  final String assetId;
  @override
  State<AssetDeleteButton> createState() => _AssetDeleteButtonState();
}

class _AssetDeleteButtonState extends State<AssetDeleteButton> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    if (!context.watch<AuthState>().isManager) return const SizedBox.shrink();
    return IconButton(tooltip: '삭제', icon: const Icon(Icons.delete_outline),
      onPressed: _busy ? null : () async {
        setState(() => _busy = true);
        try {
          if (await performAssetAction(context, AssetAction.delete,
              assetId: widget.assetId, label: '이 장비를 삭제합니다.') && context.mounted) {
            Navigator.pop(context, true);
          }
        } finally { if (mounted) setState(() => _busy = false); }
      });
  }
}
