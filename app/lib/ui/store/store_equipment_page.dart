import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';
import '../common/inventory_serial_field.dart';
import '../../core/api_exception.dart';

import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/inventory.dart';
import '../../models/store.dart';
import '../format.dart';
import '../inventory/asset_actions.dart';
import '../inventory/asset_destination.dart';
import '../theme.dart';

class StoreEquipmentPage extends StatefulWidget {
  const StoreEquipmentPage({super.key, required this.storeId});
  final String storeId;
  @override
  State<StoreEquipmentPage> createState() => _StoreEquipmentPageState();
}

class _EquipmentDraft {
  _EquipmentDraft(
    this.setNo,
    String? label,
    this.gripper,
    List<CodeItem> kinds,
    List<CodeItem> models,
    List<AssetInStore> assets,
  ) : name = TextEditingController(text: label),
      note = TextEditingController() {
    for (final k in kinds) {
      final asset = assets.where((a) => a.category?.id == k.id).firstOrNull;
      fields[k.id] = GlobalKey<InventorySerialFieldState>();
      serials[k.id] = TextEditingController(text: asset?.serialNo);
      modelNames[k.id] =
          asset?.modelName ??
          models.where((m) => m.parentId == k.id).firstOrNull?.name;
    }
  }
  final int setNo;
  final TextEditingController name, note;
  String gripper;
  final serials = <String, TextEditingController>{};
  final fields = <String, GlobalKey<InventorySerialFieldState>>{};
  final modelNames = <String, String?>{};
  void dispose() {
    name.dispose();
    note.dispose();
    for (final c in serials.values) {
      c.dispose();
    }
  }
}

class _StoreEquipmentPageState extends State<StoreEquipmentPage> {
  Store? _store;
  List<CodeItem> _kinds = [], _models = [];
  final _drafts = <_EquipmentDraft>[];
  DateTime? _date;
  bool _loading = true, _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  List<AssetInStore> get _assets =>
      _store!.assetGroups.expand((g) => g.assets).toList()
        ..sort((a, b) => a.setNo.compareTo(b.setNo));

  void _sync(Store store, {bool reset = false}) {
    _store = store;
    if (reset) {
      for (final d in _drafts) {
        d.dispose();
      }
      _drafts.clear();
    }
    final removed = _drafts
        .where((d) => !store.sets.any((s) => s.setNo == d.setNo))
        .toList();
    for (final d in removed) {
      _drafts.remove(d);
      d.dispose();
    }
    for (final s in store.sets) {
      if (_drafts.any((d) => d.setNo == s.setNo)) continue;
      final assets = _assets.where((a) => a.setNo == s.setNo).toList();
      final gripper = assets.any((a) => a.category?.name == '비전동 그리퍼')
          ? '비전동'
          : assets.any((a) => a.category?.name == '전동 그리퍼')
          ? '전동'
          : store.gripperType ?? '전동';
      _drafts.add(
        _EquipmentDraft(s.setNo, s.name, gripper, _kinds, _models, assets),
      );
    }
    _drafts.sort((a, b) => a.setNo.compareTo(b.setNo));
  }

  Future<void> _load() async {
    final success = await runGuarded(context, () async {
      final data = await Future.wait([
        context.read<StoreRepository>().get(widget.storeId),
        context.read<AdminRepository>().codeGroup('ASSET_CATEGORY'),
        context.read<AdminRepository>().codeGroup('ASSET_MODEL'),
      ]);
      if (!mounted) return;
      setState(() {
        _kinds = (data[1] as CodeGroup).selectable;
        _models = (data[2] as CodeGroup).selectable;
        final store = data[0] as Store;
        _date = store.installDate;
        _sync(store, reset: true);
      });
    });
    if (mounted) setState(() => _loading = false);
    if (!success) return;
  }

  Future<void> _changeSet(
    Future<Store> Function(StoreRepository) action,
  ) async {
    setState(() => _saving = true);
    await runGuarded(context, () async {
      final store = await action(context.read<StoreRepository>());
      if (mounted) setState(() => _sync(store));
    });
    if (mounted) setState(() => _saving = false);
  }

  bool _visible(CodeItem k, _EquipmentDraft d) =>
      k.name != (d.gripper == '전동' ? '비전동 그리퍼' : '전동 그리퍼');

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    if (_store?.isClosed == true &&
        !await ConfirmDialog.show(
          context,
          title: '폐점 매장',
          message: '폐점 매장의 장비 설정을 변경하시겠습니까?',
          confirmLabel: '변경',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    await runGuarded(context, () async {
      bool valid = true;
      for (final d in _drafts) {
        for (final k in _kinds.where((k) => _visible(k, d))) {
          if (await d.fields[k.id]!.currentState?.validate() != true) {
            valid = false;
          }
        }
      }
      if (!valid || !mounted) return;
      try {
        final result = await context.read<StoreRepository>().setupEquipment(
          widget.storeId,
          installDate: _date,
          sets: [
            for (final d in _drafts)
              {
                'set_no': d.setNo,
                'name': d.name.text.trim(),
                'gripper_type': d.gripper,
                'note': d.note.text.trim(),
                'slots': [
                  for (final k in _kinds.where((k) => _visible(k, d)))
                    {
                      'category_id': k.id,
                      'serial_no': d.serials[k.id]!.text.trim(),
                      'model_name': d.modelNames[k.id],
                    },
                ],
              },
          ],
        );
        if (!mounted) return;
        await inventoryResult(
          context,
          '장비 설정 결과',
          '추가 ${result.added.length}대 · 이동 ${result.moved.length}대 · 유지 ${result.kept.length}대\n\n${[...result.added, ...result.moved, ...result.kept].join('\n')}',
        );
        if (mounted) {
          setState(() {
            _sync(result.store, reset: true);
            _date = result.store.installDate;
          });
        }
      } on ApiException catch (error) {
        if (error.code != 'SERIAL_UNKNOWN') rethrow;
        if (!mounted) return;
        final unknown = error.details is Map
            ? error.details['unknown'] as List? ?? []
            : [];
        InventorySerialFieldState? first;
        for (final d in _drafts) {
          for (final k in _kinds.where((k) => _visible(k, d))) {
            final serial = d.serials[k.id]!.text.trim().toLowerCase();
            if (serial.isNotEmpty &&
                unknown.any(
                  (v) =>
                      v.toString().toLowerCase() == serial ||
                      v.toString().toLowerCase() ==
                          '${k.name} $serial'.toLowerCase(),
                )) {
              final field = d.fields[k.id]!.currentState;
              field?.markUnknown();
              first ??= field;
            }
          }
        }
        first?.showRegistrationHint();
      }
    });
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _moveSet(AssetInStore asset, int number) async {
    setState(() => _saving = true);
    await runGuarded(context, () async {
      await context.read<InventoryRepository>().move(
        asset.id,
        type: MovementType.move,
        toStoreId: widget.storeId,
        toSetNo: number,
      );
      if (!mounted) return;
      final store = await context.read<StoreRepository>().get(widget.storeId);
      if (mounted) setState(() => _sync(store, reset: true));
    });
    if (mounted) setState(() => _saving = false);
  }

  Widget _slot(_EquipmentDraft d, CodeItem k) {
    final serial = Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: InventorySerialField(
        key: d.fields[k.id],
        controller: d.serials[k.id]!,
        categoryId: k.id,
        label: '${k.name} S/N',
        helperText:
            '재고에 있는 S/N 만 · 다른 매장에 있던 장비는 이 매장으로 옮겨집니다'
            '${k.name == '비전동 그리퍼' ? '\n비우면 관리 번호가 자동으로 부여됩니다.' : '\n비우면 건너뜁니다.'}',
      ),
    );
    final model = inventoryChoice('${k.name} 품명', d.modelNames[k.id], {
      if (d.modelNames[k.id] != null) d.modelNames[k.id]!: d.modelNames[k.id]!,
      for (final m in _models.where((m) => m.parentId == k.id)) m.name: m.name,
    }, (v) => setState(() => d.modelNames[k.id] = v));
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: AppTheme.isWide(context)
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: serial),
                const SizedBox(width: 12),
                Expanded(child: model),
              ],
            )
          : Column(children: [serial, const FormGap(), model]),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${_store?.name ?? '매장'} 장비 설정')),
    body: _loading
        ? const LoadingState()
        : _store == null
        ? ErrorState(message: '장비 설정을 불러오지 못했습니다', onRetry: _load)
        : PageBody(
            child: Column(
              children: [
                Expanded(
                  child: AbsorbPointer(
                    absorbing: _saving,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('설치일'),
                            subtitle: Text(Fmt.date(_date)),
                            trailing: IconButton(
                              onPressed: () => setState(() => _date = null),
                              icon: const Icon(Icons.clear),
                            ),
                            onTap: () async {
                              final date = await pickDate(
                                context,
                                _date ?? DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (date != null && mounted) {
                                setState(() => _date = date);
                              }
                            },
                          ),
                          CardStack(
                            children: [
                              for (final d in _drafts)
                                SectionCard(
                                  key: ValueKey(d),
                                  title: '세트 ${d.setNo}',
                                  actions: [
                                    IconButton(
                                      tooltip: '세트 삭제',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () async {
                                        if (await ConfirmDialog.show(
                                              context,
                                              title: '세트 삭제',
                                              message:
                                                  '세트 ${d.setNo}을 삭제하시겠습니까?',
                                              confirmLabel: '삭제',
                                              destructive: true,
                                            ) &&
                                            mounted) {
                                          _changeSet(
                                            (repo) => repo.deleteSet(
                                              widget.storeId,
                                              d.setNo,
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  ],
                                  child: FormSection(
                                    title: '장비 정보',
                                    children: [
                                      Row(
                                        spacing: 12,
                                        children: [
                                          Expanded(
                                            child: TextField(
                                              controller: d.name,
                                              decoration: const InputDecoration(
                                                labelText: '세트 이름',
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () => _changeSet(
                                              (repo) => repo.renameSet(
                                                widget.storeId,
                                                d.setNo,
                                                d.name.text.trim(),
                                              ),
                                            ),
                                            child: const Text('이름 저장'),
                                          ),
                                        ],
                                      ),

                                      RadioGroup<String>(
                                        groupValue: d.gripper,
                                        onChanged: (v) =>
                                            setState(() => d.gripper = v!),
                                        child: const Wrap(
                                          spacing: 8,
                                          runSpacing: 12,
                                          children: [
                                            SizedBox(
                                              width: 150,
                                              child: RadioListTile<String>(
                                                value: '전동',
                                                title: Text('전동'),
                                              ),
                                            ),
                                            SizedBox(
                                              width: 150,
                                              child: RadioListTile<String>(
                                                value: '비전동',
                                                title: Text('비전동'),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      TextField(
                                        controller: d.note,
                                        decoration: const InputDecoration(
                                          labelText: '세트 메모',
                                        ),
                                      ),
                                      for (final k in _kinds.where(
                                        (k) => _visible(k, d),
                                      ))
                                        _slot(d, k),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: AppSpace.lg),
                          OutlinedButton.icon(
                            onPressed: () => _changeSet(
                              (repo) => repo.addSet(widget.storeId),
                            ),
                            icon: const Icon(Icons.add),
                            label: const Text('세트 추가'),
                          ),

                          const FormGap(),
                          Text(
                            '현재 설치 장비',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            '장비별 세트를 바꾸면 입력 중인 장비 설정은 현재 설치 정보로 갱신됩니다.',
                          ),
                          ResponsiveTable.fromDataRows(
                            columns: const [
                              DataColumn(label: Text('세트')),
                              DataColumn(label: Text('종류')),
                              DataColumn(label: Text('S/N')),
                              DataColumn(label: Text('상태')),
                              DataColumn(label: Text('세트 바꾸기')),
                              DataColumn(label: Text('작업')),
                            ],
                            rows: [
                              for (final a in _assets)
                                DataRow(
                                  cells: [
                                    DataCell(Text('${a.setNo}')),
                                    DataCell(Text(a.category?.name ?? a.name)),
                                    DataCell(Text(a.serialNo ?? a.assetNo)),
                                    DataCell(Text(a.statusLabel)),
                                    DataCell(
                                      DropdownButton<int>(
                                        value: a.setNo,
                                        items: [
                                          for (final n in {
                                            0,
                                            a.setNo,
                                            ..._store!.sets.map((s) => s.setNo),
                                          })
                                            DropdownMenuItem(
                                              value: n,
                                              child: Text(
                                                n == 0 ? '미지정' : '세트 $n',
                                              ),
                                            ),
                                        ],
                                        onChanged: (v) {
                                          if (v != null && v != a.setNo) {
                                            _moveSet(a, v);
                                          }
                                        },
                                      ),
                                    ),
                                    DataCell(
                                      AssetActionsMenu(
                                        key: ValueKey(a.id),
                                        assetId: a.id,
                                        label:
                                            '${a.name} S/N ${a.serialNo ?? a.assetNo}',
                                        atStore: true,
                                        onChanged: _load,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                FormActions(
                  child: FilledButton(
                    onPressed: _saving || _drafts.isEmpty ? null : _save,
                    child: Text(_saving ? '저장 중' : '장비 설정 저장'),
                  ),
                ),
              ],
            ),
          ),
  );
}
