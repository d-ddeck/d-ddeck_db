import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/store_repository.dart';
import '../../models/common.dart';
import '../../models/store.dart';

/// 매장 등록 / 수정.
///
/// 폐점 처리가 여기 있는 이유: 구 서버에서 폐점은 단순한 표시가 아니라 그
/// 매장에 설치된 장비를 어디로 거두어들일지까지 정하는 일이었다. 지금은 표시만
/// 바꾸고 장비는 재고 화면에서 옮기므로, 남아 있는 장비 수를 같이 보여 준다.
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

  String? _brandId;
  String? _gripperType;
  late bool _isClosed;
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
    _brandId = s?.brandId;
    _gripperType = s?.gripperType;
    _isClosed = s?.isClosed ?? false;
    _openDate = s?.openDate;
    _closedDate = s?.closedDate;
    _loadBrands();
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadBrands() async {
    try {
      final group =
          await context.read<AdminRepository>().codeGroup('STORE_BRAND');
      if (!mounted) return;
      setState(() {
        _brands = group.items.where((i) => i.isActive).toList();
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

  Future<void> _pickDate({required bool closing}) async {
    final initial =
        (closing ? _closedDate : _openDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
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

    // 장비가 남아 있는 매장을 폐점으로 넘기면 그 장비들이 "폐점한 매장에
    // 설치됨" 상태로 남는다. 막지는 않되 반드시 알린다.
    final held = widget.store?.assetCount ?? 0;
    if (_isClosed && !(widget.store?.isClosed ?? false) && held > 0) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('폐점 처리'),
          content: Text(
            '이 매장에 장비 $held대가 설치된 것으로 남아 있습니다.\n'
            '폐점으로 저장해도 장비는 그대로 남으니, 재고 화면에서 창고나 '
            '회수 상태로 옮겨 주세요.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('폐점으로 저장')),
          ],
        ),
      );
      if (go != true) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = context.read<StoreRepository>();
    try {
      if (_isNew) {
        await repo.create(
          name: _name.text.trim(),
          brandId: _brandId,
          gripperType: _gripperType,
          note: _note.text.trim(),
        );
      } else {
        await repo.update(widget.store!.id, {
          'name': _name.text.trim(),
          'brand_id': _brandId,
          'gripper_type': _gripperType,
          'note': _note.text.trim(),
          'is_closed': _isClosed,
          'open_date': _openDate?.toIso8601String().split('T').first,
          'closed_date':
              _isClosed ? _closedDate?.toIso8601String().split('T').first : null,
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isNew ? '매장을 등록했습니다.' : '매장 정보를 저장했습니다.')),
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
      appBar: AppBar(title: Text(_isNew ? '매장 등록' : '매장 수정')),
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
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '매장명 *'),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? '매장명을 입력해 주세요.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _brandId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '브랜드'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('미지정')),
                      for (final b in _brands)
                        DropdownMenuItem(value: b.id, child: Text(b.name)),
                    ],
                    onChanged: (v) => setState(() => _brandId = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _gripperType,
                    decoration: const InputDecoration(labelText: '그리퍼 종류'),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('지정 안 함')),
                      DropdownMenuItem(value: '전동', child: Text('전동')),
                      DropdownMenuItem(value: '비전동', child: Text('비전동')),
                    ],
                    onChanged: (v) => setState(() => _gripperType = v),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('개점일'),
                    subtitle: Text(_openDate == null
                        ? '지정 안 함'
                        : _openDate!.toIso8601String().split('T').first),
                    trailing: const Icon(Icons.calendar_today, size: 18),
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
                      onChanged: (v) => setState(() => _isClosed = v),
                    ),
                    if (_isClosed)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('폐점일'),
                        subtitle: Text(_closedDate == null
                            ? '지정 안 함'
                            : _closedDate!.toIso8601String().split('T').first),
                        trailing: const Icon(Icons.calendar_today, size: 18),
                        onTap: () => _pickDate(closing: true),
                      ),
                  ],
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
                    label: Text(_isNew ? '등록' : '저장'),
                  ),
                ],
              ),
            ),
    );
  }
}
