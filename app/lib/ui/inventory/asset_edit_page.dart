import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/admin_repository.dart';
import '../../data/inventory_repository.dart';
import '../../models/common.dart';
import '../../models/inventory.dart';
import '../async_view.dart';
import '../common/common.dart';
import '../format.dart';

class AssetEditPage extends StatefulWidget {
  const AssetEditPage({super.key, required this.asset});
  final Asset asset;
  @override
  State<AssetEditPage> createState() => _AssetEditPageState();
}

class _AssetEditPageState extends State<AssetEditPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.asset.name);
  late final _model = TextEditingController(text: widget.asset.modelName);
  late final _maker = TextEditingController(text: widget.asset.manufacturer);
  late final _serial = TextEditingController(text: widget.asset.serialNo);
  late final _note = TextEditingController(text: widget.asset.note);
  late String? _category = widget.asset.categoryId;
  late DateTime? _date = widget.asset.purchaseDate;
  bool _busy = false;
  @override
  void dispose() {
    for (final c in [_name, _model, _maker, _serial, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await runGuarded(context, () async {
      await context.read<InventoryRepository>().update(widget.asset.id, {
        'name': _name.text.trim(),
        'category_id': _category,
        'model_name': _model.text.trim(),
        'manufacturer': _maker.text.trim(),
        'serial_no': _serial.text.trim(),
        'note': _note.text.trim(),
        'purchase_date': _date == null ? null : Fmt.date(_date),
      });
    }, successMessage: '장비 정보를 수정했습니다.');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => DirtyFormScope(
    busy: _busy,
    snapshot: () => [
      _name.text,
      _model.text,
      _maker.text,
      _serial.text,
      _note.text,
      _category,
      _date,
    ].toString(),
    child: Scaffold(
      appBar: AppBar(title: const Text('장비 정보 수정')),
      body: PageBody(
        child: AsyncView<CodeGroup>(
          load: () =>
              context.read<AdminRepository>().codeGroup('ASSET_CATEGORY'),
          builder: (context, group, _) => Form(
            key: _form,
            child: FormListView(
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '장비 이름'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '이름을 입력하세요.' : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: '종류'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('미지정')),
                    for (final c in group.items.where(
                      (c) => c.isActive || c.id == _category,
                    ))
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) =>
                      setState(() => _category = v == '' ? null : v),
                ),
                for (final entry in [
                  (_model, '품명'),
                  (_maker, '제조사'),
                  (_serial, 'S/N'),
                  (_note, '비고'),
                ])
                  TextFormField(
                    controller: entry.$1,
                    decoration: InputDecoration(labelText: entry.$2),
                  ),
                ListTile(
                  title: const Text('설치일'),
                  subtitle: Text(Fmt.date(_date)),
                  trailing: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _date = null),
                  ),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (d != null && mounted) setState(() => _date = d);
                  },
                ),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? '저장 중…' : '저장'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
