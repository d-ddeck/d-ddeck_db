import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../data/store_repository.dart';
import '../../models/admin.dart';
import '../../models/common.dart';
import '../../models/inventory.dart';
import '../../models/store.dart';
import '../format.dart';
import 'asset_destination.dart';

class AssetFormPage extends StatefulWidget {
  const AssetFormPage({super.key, this.presetStoreId});
  final String? presetStoreId;
  @override
  State<AssetFormPage> createState() => _AssetFormPageState();
}

class _AssetFormPageState extends State<AssetFormPage> {
  final _form = GlobalKey<FormState>();
  final _serial = TextEditingController();
  final _note = TextEditingController();
  final _destination = AssetDestination();
  List<CodeItem> _categories = [], _models = [], _makers = [], _statuses = [];
  List<StorageLocation> _locations = [];
  List<Store> _stores = [];
  List<String> _requiredMakers = [];
  String? _categoryId, _modelId, _makerId;
  DateTime? _installDate;
  bool _loading = true, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _serial.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final admin = context.read<AdminRepository>();
      final data = await Future.wait([
        admin.codeGroup('ASSET_CATEGORY'),
        admin.codeGroup('ASSET_MODEL'),
        admin.codeGroup('ASSET_MAKER'),
        admin.codeGroup('ASSET_STATUS'),
        admin.settings(SettingsModule.inventory),
        context.read<InventoryRepository>().locations(),
        context.read<StoreRepository>().all(includeClosed: true),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = (data[0] as CodeGroup).selectable;
        _models = (data[1] as CodeGroup).selectable;
        _makers = (data[2] as CodeGroup).selectable;
        _statuses = (data[3] as CodeGroup).selectable;
        _requiredMakers =
            (data[4] as ModuleSettings).settings
                .where((s) => s.key == 'maker_required_categories')
                .firstOrNull
                ?.asStringList ??
            [];
        _locations = data[5] as List<StorageLocation>;
        _stores = data[6] as List<Store>;
        _destination.storeId = widget.presetStoreId;
        _destination.toStore = widget.presetStoreId != null;
        if (_destination.toStore) {
          _destination.statusId = _statuses
              .where(
                (s) =>
                    s.extra['rule'] == 'store' && s.extra['enum'] == 'IN_USE',
              )
              .firstOrNull
              ?.id;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        inventoryMessage(context, e.message);
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final closed = _stores
        .where((s) => s.id == _destination.storeId && s.isClosed)
        .firstOrNull;
    if (closed != null &&
        !await ConfirmDialog.show(
          context,
          title: '폐점 매장',
          message: '${closed.name}은(는) 폐점 매장입니다. 장비를 등록하시겠습니까?',
          confirmLabel: '등록',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final result = await context.read<InventoryRepository>().createBulk(
        serialNos: _serial.text
            .split(RegExp(r'[\r\n,]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        categoryId: _categoryId,
        modelName: _models.where((s) => s.id == _modelId).firstOrNull?.name,
        manufacturer: _makers.where((s) => s.id == _makerId).firstOrNull?.name,
        statusItemId: _destination.statusId,
        storeId: _destination.storeId,
        locationId: _destination.locationId,
        setNo: _destination.setNo ?? 0,
        purchaseDate: _installDate,
        note: _note.text.trim(),
      );
      if (!mounted) return;
      await inventoryResult(
        context,
        '${result.created.length}대 등록, 중복 ${result.duplicates.length}개 건너뜀',
        result.duplicates.isEmpty
            ? '등록했습니다.'
            : '중복 S/N\n${result.duplicates.join('\n')}',
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) inventoryMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final category = _categories.where((s) => s.id == _categoryId).firstOrNull;
    return DirtyFormScope(
      ready: !_loading,
      busy: _saving,
      snapshot: () => [
        _serial.text,
        _note.text,
        _categoryId,
        _modelId,
        _makerId,
        _installDate,
        _destination.statusId,
        _destination.brandId,
        _destination.storeId,
        _destination.locationId,
        _destination.setNo,
        _destination.toStore,
        _destination.clearStore,
      ].toString(),
      child: Scaffold(
        appBar: AppBar(title: const Text('장비 등록')),
        body: _loading
            ? const LoadingState()
            : _error != null
            ? ErrorState(message: _error!, onRetry: _load)
            : PageBody(
                child: Form(
                  key: _form,
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            FormSection(
                              title: '장비 정보',
                              children: [
                                inventoryChoice(
                                  '종류',
                                  _categoryId,
                                  {for (final c in _categories) c.id: c.name},
                                  (v) => setState(() {
                                    _categoryId = v;
                                    _modelId = _models
                                        .where((m) => m.parentId == v)
                                        .firstOrNull
                                        ?.id;
                                    _makerId = null;
                                  }),
                                  required: true,
                                ),

                                inventoryChoice('품명', _modelId, {
                                  for (final m in _models.where(
                                    (m) => m.parentId == _categoryId,
                                  ))
                                    m.id: m.name,
                                }, (v) => setState(() => _modelId = v)),

                                inventoryChoice(
                                  '제조사',
                                  _makerId,
                                  {
                                    for (final m in _makers.where(
                                      (m) => m.parentId == _categoryId,
                                    ))
                                      m.id: m.name,
                                  },
                                  (v) => setState(() => _makerId = v),
                                  required: _requiredMakers.contains(
                                    category?.name,
                                  ),
                                ),

                                TextFormField(
                                  controller: _serial,
                                  minLines: 3,
                                  maxLines: 8,
                                  decoration: const InputDecoration(
                                    labelText: 'S/N 여러 개 *',
                                    helperText: '줄 또는 쉼표로 구분합니다.',
                                  ),
                                  validator: (v) =>
                                      (v ?? '')
                                          .split(RegExp(r'[\r\n,]+'))
                                          .every((s) => s.trim().isEmpty)
                                      ? 'S/N을 입력해 주세요.'
                                      : null,
                                ),
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              title: '상태 · 위치',
                              children: [
                                AssetDestinationFields(
                                  value: _destination,
                                  statuses: _statuses,
                                  stores: _stores,
                                  locations: _locations,
                                  registration: true,
                                ),
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              title: '기타',
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('설치일'),
                                  subtitle: Text(Fmt.date(_installDate)),
                                  trailing: IconButton(
                                    onPressed: () =>
                                        setState(() => _installDate = null),
                                    icon: const Icon(Icons.clear),
                                  ),
                                  onTap: () async {
                                    final date = await pickDate(
                                      context,
                                      _installDate ?? DateTime.now(),
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime(2100),
                                    );
                                    if (date != null && mounted) {
                                      setState(() => _installDate = date);
                                    }
                                  },
                                ),

                                TextFormField(
                                  controller: _note,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                    labelText: '비고',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      FormActions(
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? '등록 중' : '등록'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
