import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../format.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/store.dart';
import '../../state/auth_state.dart';
import '../inventory/asset_destination.dart';
import 'store_equipment_page.dart';

/// 매장 등록 / 수정. 폐점은 회수 상태를 확인한 뒤 전용 API로 저장한다.
class StoreFormPage extends StatefulWidget {
  const StoreFormPage({super.key, this.store});

  /// null 이면 신규 등록.
  final Store? store;

  @override
  State<StoreFormPage> createState() => _StoreFormPageState();
}

class _StoreFormPageState extends State<StoreFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _note;
  late final TextEditingController _contactName, _contactPhone, _address;

  String? _brandId;
  String? _gripperType;
  late bool _isClosed;
  late bool _isActive;
  DateTime? _openDate;
  DateTime? _closedDate;

  List<CodeItem> _brands = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.store == null;

  @override
  void initState() {
    super.initState();
    final s = widget.store;
    _name = TextEditingController(text: s?.name ?? '');
    _note = TextEditingController(text: s?.note ?? '');
    _contactName = TextEditingController(text: s?.contactName ?? '');
    _contactPhone = TextEditingController(text: s?.contactPhone ?? '');
    _address = TextEditingController(text: s?.address ?? '');
    _brandId = s?.brandId;
    _gripperType = s?.gripperType;
    _isClosed = s?.isClosed ?? false;
    _isActive = s?.isActive ?? true;
    _openDate = s?.openDate;
    _closedDate = s?.closedDate;
    _loadBrands();
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _contactName.dispose();
    _contactPhone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _loadBrands() async {
    try {
      final group = await context.read<AdminRepository>().codeGroup(
        'STORE_BRAND',
      );
      if (!mounted) return;
      setState(() {
        _brands = group.items
            .where((i) => i.isActive || i.id == _brandId)
            .toList();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      inventoryMessage(context, e.message);
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _pickDate({required bool closing}) async {
    final initial = (closing ? _closedDate : _openDate) ?? DateTime.now();
    final picked = await pickDate(
      context,
      initial,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      if (closing) {
        _closedDate = picked;
      } else {
        _openDate = picked;
      }
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_isNew && !context.read<AuthState>().isAdmin) return;

    String? recoverId;
    if (!_isNew && _isClosed) {
      final store = widget.store!;
      recoverId = store.recoverOptions.firstOrNull?.id;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => ConfirmDialog.form(
            destructive: true,
            title: const Text('폐점 처리'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('설치 장비 ${store.movableCount}대가 옮겨집니다'),
                    if (store.rentalCount > 0)
                      Text('렌탈 중 ${store.rentalCount}대는 대응 기록에서 회수 처리'),
                    RadioGroup<String>(
                      groupValue: recoverId ?? '',
                      onChanged: (v) =>
                          update(() => recoverId = v == '' ? null : v),
                      child: Column(
                        children: [
                          for (final option in store.recoverOptions)
                            RadioListTile<String>(
                              value: option.id,
                              title: Text(option.name),
                            ),
                          const RadioListTile<String>(
                            value: '',
                            title: Text('옮기지 않음'),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      title: const Text('폐점일'),
                      subtitle: Text(
                        (_closedDate == null ? null : Fmt.date(_closedDate)) ??
                            '지정 안 함',
                      ),
                      onTap: () async {
                        final date = await pickDate(
                          ctx,
                          _closedDate ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (date != null && ctx.mounted) {
                          update(() => _closedDate = date);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('폐점으로 저장'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = context.read<StoreRepository>();
    try {
      if (_isNew) {
        final created = await repo.create(
          name: _name.text.trim(),
          contactName: _contactName.text.trim(),
          contactPhone: _contactPhone.text.trim(),
          address: _address.text.trim(),
          openDate: _openDate,
          brandId: _brandId,
          gripperType: _gripperType,
          note: _note.text.trim(),
        );
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StoreEquipmentPage(storeId: created.id),
          ),
        );
      } else {
        await repo.update(widget.store!.id, {
          'name': _name.text.trim(),
          'contact_name': _contactName.text.trim(),
          'contact_phone': _contactPhone.text.trim(),
          'address': _address.text.trim(),
          'brand_id': _brandId,
          'gripper_type': _gripperType,
          'note': _note.text.trim(),
          'is_active': _isActive,
          if (!_isClosed) 'is_closed': false,
          'open_date': _openDate?.toIso8601String().split('T').first,
          if (!_isClosed) 'closed_date': null,
        });
        if (_isClosed) {
          final result = await repo.close(
            widget.store!.id,
            closedDate: _closedDate,
            recoverToStatusItemId: recoverId,
            note: _note.text.trim(),
          );
          if (!mounted) return;
          await inventoryResult(
            context,
            '폐점 처리 결과',
            '이동 ${result.moved.length}대\n${result.moved.join('\n')}\n\n${result.notices.join('\n')}',
          );
        }
      }
      if (!mounted) return;
      AppSnack.show(context, '${_name.text.trim()} 매장 정보를 저장했습니다.');
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      inventoryMessage(context, e.message);
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DirtyFormScope(
      ready: !_loading,
      busy: _saving,
      snapshot: () => [
        _name.text,
        _note.text,
        _brandId,
        _gripperType,
        _isClosed,
        _isActive,
        _openDate,
        _closedDate,
      ].toString(),
      child: Scaffold(
        appBar: AppBar(title: Text(_isNew ? '매장 등록' : '매장 수정')),
        body: _loading
            ? const LoadingState()
            : PageBody(
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            if (_error != null)
                              Card(
                                color: Theme.of(
                                  context,
                                ).colorScheme.errorContainer,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(_error!),
                                ),
                              ),
                            if (_error != null) const FormGap(),
                            FormSection(
                              title: '매장 연락 정보',
                              children: [
                                TextFormField(
                                  controller: _contactName,
                                  maxLength: 150,
                                  decoration: const InputDecoration(
                                    labelText: '매장 담당자',
                                  ),
                                ),
                                TextFormField(
                                  controller: _contactPhone,
                                  maxLength: 50,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: '연락처',
                                  ),
                                ),
                                TextFormField(
                                  controller: _address,
                                  maxLength: 300,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                    labelText: '주소',
                                    alignLabelWithHint: true,
                                  ),
                                ),
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              title: '기본 정보',
                              children: [
                                TextFormField(
                                  controller: _name,
                                  decoration: const InputDecoration(
                                    labelText: '매장명 *',
                                  ),
                                  validator: (v) =>
                                      (v == null || v.trim().isEmpty)
                                      ? '매장명을 입력해 주세요.'
                                      : null,
                                ),

                                DropdownButtonFormField<String>(
                                  initialValue: _brandId,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '브랜드',
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('미지정'),
                                    ),
                                    for (final b in _brands)
                                      DropdownMenuItem(
                                        value: b.id,
                                        child: Text(b.name),
                                      ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _brandId = v),
                                ),

                                DropdownButtonFormField<String>(
                                  initialValue: _gripperType,
                                  decoration: const InputDecoration(
                                    labelText: '그리퍼 종류',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: null,
                                      child: Text('지정 안 함'),
                                    ),
                                    DropdownMenuItem(
                                      value: '전동',
                                      child: Text('전동'),
                                    ),
                                    DropdownMenuItem(
                                      value: '비전동',
                                      child: Text('비전동'),
                                    ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _gripperType = v),
                                ),

                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('개점일'),
                                  subtitle: Text(
                                    _openDate == null
                                        ? '지정 안 함'
                                        : Fmt.date(_openDate),
                                  ),
                                  trailing: const Icon(
                                    Icons.calendar_today,
                                    size: 18,
                                  ),
                                  onTap: () => _pickDate(closing: false),
                                ),
                                if (!_isNew) ...[
                                  const Divider(),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('폐점'),
                                    subtitle: Text(
                                      widget.store!.assetCount > 0
                                          ? '장비 ${widget.store!.assetCount}대가 설치되어 있습니다'
                                          : '설치된 장비 없음',
                                    ),
                                    value: _isClosed,
                                    onChanged: (v) =>
                                        setState(() => _isClosed = v),
                                  ),
                                  if (_isClosed)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('폐점일'),
                                      subtitle: Text(
                                        _closedDate == null
                                            ? '지정 안 함'
                                            : Fmt.date(_closedDate),
                                      ),
                                      trailing: const Icon(
                                        Icons.calendar_today,
                                        size: 18,
                                      ),
                                      onTap: () => _pickDate(closing: true),
                                    ),
                                ],

                                if (!_isNew)
                                  SwitchListTile(
                                    title: const Text("매장 활성화"),
                                    subtitle: const Text(
                                      "비활성 매장은 기본 목록에서 숨겨집니다.",
                                    ),
                                    value: _isActive,
                                    onChanged: (v) =>
                                        setState(() => _isActive = v),
                                  ),
                                TextFormField(
                                  controller: _note,
                                  decoration: const InputDecoration(
                                    labelText: '비고',
                                  ),
                                  maxLines: 3,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      FormActions(
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check),
                          label: Text(_isNew ? '등록' : '저장'),
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
