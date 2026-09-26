import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/inventory.dart';
import '../../models/store.dart';

void inventoryMessage(BuildContext context, String message) =>
    AppSnack.show(context, message);

Future<void> inventoryResult(BuildContext context, String title, String text) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => ConfirmDialog.form(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );

Widget inventoryChoice(
  String label,
  String? value,
  Map<String, String> choices,
  ValueChanged<String?> onChanged, {
  bool required = false,
  String empty = '선택 안 함',
}) {
  return DropdownButtonFormField<String>(
    key: ValueKey('$label:$value:${choices.keys.join(',')}'),
    initialValue: choices.containsKey(value) ? value : '',
    isExpanded: true,
    decoration: InputDecoration(labelText: '$label${required ? ' *' : ''}'),
    items: [
      DropdownMenuItem(value: '', child: Text(empty)),
      for (final e in choices.entries)
        DropdownMenuItem(
          value: e.key,
          child: Text(e.value, overflow: TextOverflow.ellipsis),
        ),
    ],
    validator: required
        ? (v) => v == null || v.isEmpty ? '$label 선택이 필요합니다.' : null
        : null,
    onChanged: (v) => onChanged(v == '' ? null : v),
  );
}

class AssetDestination {
  String? statusId;
  String? brandId;
  String? storeId;
  String? locationId;
  int? setNo;
  bool toStore = false;
  bool clearStore = false;
}

/// 등록과 단건/일괄 이동이 같은 ASSET_STATUS.extra 규칙을 사용한다.
class AssetDestinationFields extends StatefulWidget {
  const AssetDestinationFields({
    super.key,
    required this.value,
    required this.statuses,
    required this.stores,
    required this.locations,
    this.registration = false,
  });
  final AssetDestination value;
  final List<CodeItem> statuses;
  final List<Store> stores;
  final List<StorageLocation> locations;
  final bool registration;

  @override
  State<AssetDestinationFields> createState() => _AssetDestinationFieldsState();
}

class _AssetDestinationFieldsState extends State<AssetDestinationFields> {
  List<StoreSet> _sets = [];
  int _request = 0;
  @override
  void initState() {
    super.initState();
    final d = widget.value;
    d.brandId = widget.stores
        .where((s) => s.id == d.storeId)
        .firstOrNull
        ?.brandId;
    if (d.storeId != null) _loadSets(d.storeId!);
  }

  Future<void> _loadSets(String id) async {
    final request = ++_request;
    try {
      final store = await context.read<StoreRepository>().get(id);
      if (mounted && request == _request && widget.value.storeId == id) {
        setState(() => _sets = store.sets);
      }
    } on ApiException catch (e) {
      if (mounted) inventoryMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.value;
    final status = widget.statuses.where((s) => s.id == d.statusId).firstOrNull;
    final rule = status?.extra['rule'] as String?;
    final showStore =
        rule == 'store' || rule == 'as' || (status == null && d.toStore);
    final showLocation = rule == 'free' || (status == null && !d.toStore);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        inventoryChoice(
          '세부 상태',
          d.statusId,
          {for (final s in widget.statuses) s.id: s.name},
          (v) => setState(() {
            d.statusId = v;
            d.storeId = null;
            d.brandId = null;
            d.setNo = null;
            d.locationId = null;
            d.clearStore = false;
            _sets = [];
            _request++;
          }),
          required: widget.registration,
          empty: '위치만 이동',
        ),
        const FormGap(),
        if (status == null && !widget.registration)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('매장으로 이동'),
            value: d.toStore,
            onChanged: (v) => setState(() {
              d.toStore = v;
              d.storeId = null;
              d.locationId = null;
              d.setNo = null;
              d.clearStore = false;
            }),
          ),
        if (rule == 'as')
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('매장에 둔 채 상태만 바뀝니다'),
          ),
        if (rule == 'clear')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '매장·세트가 비워지고 ${status?.extra['place'] ?? '위치 미지정'}${status?.extra['place'] == null ? '으로' : '로'} 이동합니다',
            ),
          ),
        if (showStore) ...[
          inventoryChoice(
            '브랜드',
            d.brandId,
            {
              for (final s in widget.stores)
                if (s.brandId != null) s.brandId!: s.brandName,
            },
            (v) => setState(() {
              d.brandId = v;
              d.storeId = null;
              d.setNo = null;
              _sets = [];
              _request++;
            }),
            empty: '전체 브랜드',
          ),
          const FormGap(),
          inventoryChoice(
            '매장',
            d.storeId,
            {
              for (final s in widget.stores.where(
                (s) => d.brandId == null || s.brandId == d.brandId,
              ))
                s.id: '${s.brandName} · ${s.name}',
            },
            (v) {
              setState(() {
                d.storeId = v;
                d.setNo = null;
                _sets = [];
                _request++;
              });
              if (v != null) _loadSets(v);
            },
            required: rule == 'store' || (status == null && d.toStore),
          ),
          if (d.storeId != null) ...[
            const FormGap(),
            inventoryChoice(
              '세트 번호',
              d.setNo?.toString(),
              {'0': '세트 미지정', for (final s in _sets) '${s.setNo}': s.label},
              (v) => setState(() => d.setNo = v == null ? null : int.parse(v)),
              empty: '기존 세트 유지',
            ),
          ],
        ],
        if (showLocation) ...[
          inventoryChoice('위치', d.locationId, {
            for (final l in widget.locations.where((l) => l.isActive))
              l.id: l.display,
          }, (v) => setState(() => d.locationId = v)),
          if (status == null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('매장·세트 연결 비우기'),
              value: d.clearStore,
              onChanged: (v) => setState(() => d.clearStore = v ?? false),
            ),
        ],
      ],
    );
  }
}

Future<bool> showAssetMoveDialog(
  BuildContext context,
  List<String> ids, {
  bool bulk = false,
}) async {
  final changed = AppTheme.isWide(context)
      ? await showDialog<bool>(
          context: context,
          builder: (_) => _AssetMoveDialog(ids: ids, bulk: bulk),
        )
      : await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          isDismissible: false,
          enableDrag: false,
          builder: (_) => SizedBox(
            height: MediaQuery.sizeOf(context).height,
            child: _AssetMoveDialog(ids: ids, bulk: bulk),
          ),
        );
  return changed == true;
}

class _AssetMoveDialog extends StatefulWidget {
  const _AssetMoveDialog({required this.ids, required this.bulk});
  final List<String> ids;
  final bool bulk;
  @override
  State<_AssetMoveDialog> createState() => _AssetMoveDialogState();
}

class _AssetMoveDialogState extends State<_AssetMoveDialog> {
  final _form = GlobalKey<FormState>();
  final _value = AssetDestination();
  final _reason = TextEditingController();
  List<CodeItem> _statuses = [];
  List<Store> _stores = [];
  List<StorageLocation> _locations = [];
  bool _loading = true, _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await Future.wait([
        context.read<AdminRepository>().codeGroup('ASSET_STATUS'),
        context.read<StoreRepository>().all(includeClosed: true),
        context.read<InventoryRepository>().locations(),
      ]);
      if (!mounted) return;
      setState(() {
        _statuses = (data[0] as CodeGroup).selectable;
        _stores = data[1] as List<Store>;
        _locations = data[2] as List<StorageLocation>;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        inventoryMessage(context, e.message);
        Navigator.pop(context, false);
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final d = _value;
    if (d.statusId == null &&
        d.storeId == null &&
        d.locationId == null &&
        !d.clearStore) {
      inventoryMessage(context, '상태 또는 이동할 위치를 선택해 주세요.');
      return;
    }
    final closed = _stores
        .where((s) => s.id == d.storeId && s.isClosed)
        .firstOrNull;
    if (closed != null &&
        !await ConfirmDialog.show(
          context,
          title: '폐점 매장',
          message: '${closed.name}은(는) 폐점 매장입니다. 장비를 이동하시겠습니까?',
          confirmLabel: '이동',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final repo = context.read<InventoryRepository>();
      if (widget.bulk) {
        final result = await repo.bulkMove(
          assetIds: widget.ids,
          toStoreId: d.storeId,
          toLocationId: d.locationId,
          toStatusItemId: d.statusId,
          toSetNo: d.setNo,
          clearStore: d.clearStore,
          reason: _reason.text.trim(),
        );
        if (!mounted) return;
        await inventoryResult(
          context,
          '일괄 변경 결과',
          '이동 ${result.moved.length}대\n${result.moved.join('\n')}\n\n건너뜀 ${result.skipped.length}대\n${result.skipped.join('\n')}\n\n오류 ${result.errors.length}개\n${result.errors.join('\n')}',
        );
      } else {
        await repo.move(
          widget.ids.single,
          type: MovementType.move,
          toStoreId: d.storeId,
          toLocationId: d.locationId,
          toStatusItemId: d.statusId,
          toSetNo: d.setNo,
          clearStore: d.clearStore,
          reason: _reason.text.trim(),
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) inventoryMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _loading
        ? const LoadingState()
        : Form(
            key: _form,
            child: FormSection(
              title: '이동 정보',
              children: [
                AssetDestinationFields(
                  value: _value,
                  statuses: _statuses,
                  stores: _stores,
                  locations: _locations,
                ),
                TextFormField(
                  controller: _reason,
                  decoration: const InputDecoration(labelText: '메모 (이동 사유)'),
                  maxLines: 3,
                ),
              ],
            ),
          );
    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        const SizedBox(width: AppSpace.sm),
        FilledButton(
          onPressed: _saving || _loading ? null : _save,
          child: Text(_saving ? '저장 중' : '변경'),
        ),
      ],
    );
    final title = '이동 / 상태 변경 (${widget.ids.length}대)';
    return PopScope(
      canPop: !_saving,
      child: AppTheme.isWide(context)
          ? Dialog(
              child: SizedBox(
                width: 520,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const FormGap(),
                      Flexible(child: SingleChildScrollView(child: content)),
                      FormActions(child: actions),
                    ],
                  ),
                ),
              ),
            )
          : Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: PageBody(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const FormGap(),
                    Expanded(child: SingleChildScrollView(child: content)),
                    FormActions(child: actions),
                  ],
                ),
              ),
            ),
    );
  }
}
