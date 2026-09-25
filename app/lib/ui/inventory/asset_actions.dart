import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../models/inventory.dart';
import '../../state/auth_state.dart';
import 'asset_destination.dart';

enum AssetAction { move, warehouse, delete }

const _deletePermissionMessage = '삭제는 팀장 이상만 할 수 있습니다';

Future<bool> performAssetAction(BuildContext context, AssetAction action,
    {required String assetId, required String label}) async {
  if (action == AssetAction.delete && !context.read<AuthState>().isManager) {
    AppSnack.show(context, _deletePermissionMessage);
    return false;
  }
  final repo = context.read<InventoryRepository>();
  final admin = context.read<AdminRepository>();
  try {
    if (action == AssetAction.move) {
      if (!await showAssetMoveDialog(context, [assetId])) return false;
    } else {
      final confirmed = await ConfirmDialog.show(context, title: action == AssetAction.delete ? '장비 삭제' : '매장에서 빼기 → 창고',
        message: action == AssetAction.delete
          ? '$label\n\n재고에서 완전히 지웁니다. 이력도 함께 사라집니다'
          : '$label 을 창고로 옮깁니다', confirmLabel: action == AssetAction.delete ? '삭제' : '창고로 이동', destructive: true);
      if (confirmed != true || !context.mounted) return false;
      if (action == AssetAction.delete) {
        if (!context.read<AuthState>().isManager) {
          AppSnack.show(context, _deletePermissionMessage);
          return false;
        }
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
        // Keep taps available for the permission explanation; deletion stays guarded.
        PopupMenuItem(value: AssetAction.delete,
          child: isManager ? const Text('삭제') : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('삭제', style: TextStyle(color: Theme.of(context).disabledColor)),
              Text(_deletePermissionMessage,
                style: TextStyle(fontSize: 12, color: Theme.of(context).disabledColor)),
            ],
          )),
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
    final isManager = context.watch<AuthState>().isManager;
    return IconButton(tooltip: isManager ? '삭제' : _deletePermissionMessage,
      icon: Icon(Icons.delete_outline,
        color: isManager ? null : Theme.of(context).disabledColor),
      onPressed: _busy ? null : () async {
        if (!isManager) {
          AppSnack.show(context, _deletePermissionMessage);
          return;
        }
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
