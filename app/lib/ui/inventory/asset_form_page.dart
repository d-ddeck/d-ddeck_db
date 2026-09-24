import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/inventory.dart';
import '../../models/store.dart';

/// 자산 한 대 등록.
///
/// 서버는 **위치와 매장 중 하나**를 요구한다. 창고에 들어오는 장비는 위치를,
/// 매장에 설치되는 장비는 매장을 고르면 된다. 둘 다 비우면 거절당하므로 화면이
/// 먼저 막는다.
class AssetFormPage extends StatefulWidget {
  const AssetFormPage({super.key, this.presetStoreId});

  /// 매장 화면에서 들어왔을 때 미리 골라 둘 매장.
  final String? presetStoreId;

  @override
  State<AssetFormPage> createState() => _AssetFormPageState();
}

enum _Place { warehouse, store }

class _AssetFormPageState extends State<AssetFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _serial = TextEditingController();
  final _model = TextEditingController();
  final _maker = TextEditingController();
  final _note = TextEditingController();

  _Place _place = _Place.warehouse;
  String? _categoryId;
  String? _locationId;
  String? _storeId;
  String? _statusItemId;

  List<CodeItem> _categories = const [];
  List<CodeItem> _statuses = const [];
  List<StorageLocation> _locations = const [];
  List<Store> _stores = const [];

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _storeId = widget.presetStoreId;
    if (_storeId != null) _place = _Place.store;
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _serial, _model, _maker, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final admin = context.read<AdminRepository>();
    final inv = context.read<InventoryRepository>();
    final stores = context.read<StoreRepository>();
    try {
      final results = await Future.wait([
        admin.codeGroup('ASSET_CATEGORY'),
        admin.codeGroup('ASSET_STATUS'),
        inv.locations(),
        stores.list(size: 300, includeClosed: false),
      ]);
      if (!mounted) return;
      setState(() {
        _categories =
            (results[0] as CodeGroup).items.where((i) => i.isActive).toList();
        _statuses =
            (results[1] as CodeGroup).items.where((i) => i.isActive).toList();
        _locations = results[2] as List<StorageLocation>;
        _stores = (results[3] as PagedList<Store>).items;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 종류를 고르면 품명을 자동으로 채운다. "로봇팔 RB5-850EN" 처럼 쓰는
  /// 이름이라 매번 손으로 적을 이유가 없다.
  void _syncName() {
    final cat = _categories.where((c) => c.id == _categoryId).firstOrNull;
    if (cat == null) return;
    final model = _model.text.trim();
    final suggested = model.isEmpty ? cat.name : '${cat.name} $model';
    _name.text = suggested;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final asset = await context.read<InventoryRepository>().create(
            name: _name.text.trim(),
            categoryId: _categoryId,
            locationId: _place == _Place.warehouse ? _locationId : null,
            storeId: _place == _Place.store ? _storeId : null,
            statusItemId: _statusItemId,
            status: _place == _Place.store ? AssetStatus.inUse : AssetStatus.inStock,
            modelName: _model.text.trim().isEmpty ? null : _model.text.trim(),
            manufacturer: _maker.text.trim().isEmpty ? null : _maker.text.trim(),
            serialNo: _serial.text.trim().isEmpty ? null : _serial.text.trim(),
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${asset.assetNo} 등록했습니다.')),
      );
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('자산 등록')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!),
                      ),
                    ),
                  DropdownButtonFormField<String>(
                    initialValue: _categoryId,
                    decoration: const InputDecoration(labelText: '종류 *'),
                    items: [
                      for (final c in _categories)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    validator: (v) => v == null ? '종류를 골라 주세요.' : null,
                    onChanged: (v) => setState(() {
                      _categoryId = v;
                      _syncName();
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _serial,
                    decoration: const InputDecoration(
                      labelText: 'S/N',
                      hintText: '비우면 자산번호로만 관리됩니다',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _model,
                    decoration: const InputDecoration(labelText: '모델'),
                    onChanged: (_) => _syncName(),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _maker,
                    decoration: const InputDecoration(labelText: '제조사'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '품명 *'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '품명을 입력해 주세요.' : null,
                  ),
                  const SizedBox(height: 20),
                  Text('어디에 두나요?',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<_Place>(
                    segments: const [
                      ButtonSegment(
                        value: _Place.warehouse,
                        label: Text('창고 · 사무실'),
                        icon: Icon(Icons.warehouse_outlined),
                      ),
                      ButtonSegment(
                        value: _Place.store,
                        label: Text('매장'),
                        icon: Icon(Icons.storefront_outlined),
                      ),
                    ],
                    selected: {_place},
                    onSelectionChanged: (v) => setState(() => _place = v.first),
                  ),
                  const SizedBox(height: 12),
                  if (_place == _Place.warehouse)
                    DropdownButtonFormField<String>(
                      initialValue: _locationId,
                      decoration: const InputDecoration(labelText: '위치 *'),
                      items: [
                        for (final l in _locations)
                          DropdownMenuItem(value: l.id, child: Text(l.display)),
                      ],
                      validator: (v) => v == null ? '위치를 골라 주세요.' : null,
                      onChanged: (v) => setState(() => _locationId = v),
                    )
                  else
                    DropdownButtonFormField<String>(
                      initialValue: _storeId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '매장 *'),
                      items: [
                        for (final s in _stores)
                          DropdownMenuItem(
                            value: s.id,
                            child: Text('${s.brandName} · ${s.name}',
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      validator: (v) => v == null ? '매장을 골라 주세요.' : null,
                      onChanged: (v) => setState(() => _storeId = v),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _statusItemId,
                    decoration: const InputDecoration(
                      labelText: '세부 상태',
                      helperText: '설치 / 렌탈 중 / AS 대기 …',
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('지정 안 함')),
                      for (final s in _statuses)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (v) => setState(() => _statusItemId = v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _note,
                    decoration: const InputDecoration(labelText: '비고'),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: const Text('등록'),
                  ),
                ],
              ),
            ),
    );
  }
}
