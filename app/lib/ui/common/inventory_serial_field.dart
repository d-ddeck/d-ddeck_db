import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/inventory_repository.dart';
import '../inventory/asset_form_page.dart';
import 'feedback.dart';

/// Suggestions are debounced; validation always reads fresh inventory, including
/// later pages and equipment already installed at any store.
class InventorySerialField extends StatefulWidget {
  const InventorySerialField({super.key, required this.controller, required this.label,
    this.categoryId, this.optional = true, this.multiple = false, this.helperText});
  final TextEditingController controller;
  final String label;
  final String? categoryId, helperText;
  final bool optional, multiple;

  @override
  State<InventorySerialField> createState() => InventorySerialFieldState();
}

class InventorySerialFieldState extends State<InventorySerialField> {
  final _focus = FocusNode();
  String? _error;
  int _revision = 0, _validation = 0;
  @override
  void initState() {
    super.initState();
    _focus.addListener(_blur);
    widget.controller.addListener(_changed);
  }
  void _changed() { _revision++; if (_error != null) setState(() => _error = null); }
  void _blur() { if (!_focus.hasFocus) validate(); }
  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.removeListener(_blur); _focus.dispose(); super.dispose();
  }

  void markUnknown() {
    _validation++;
    if (mounted) setState(() => _error = '재고에 등록되지 않은 S/N 입니다');
  }

  void showRegistrationHint() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('재고에 없는 S/N 은 매장에 배치할 수 없습니다. [장비 목록]에서 먼저 등록하세요'),
      action: SnackBarAction(label: '장비 등록으로', onPressed: () async {
        await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const AssetFormPage()));
        if (mounted) await validate();
      }),
    ));
  }

  Future<bool> validate({bool notify = true}) async {
    final revision = _revision;
    final validation = ++_validation;
    final text = widget.controller.text.trim();
    final serials = widget.multiple ? text.split(RegExp(r'[,;/\s]+')).where((s) => s.isNotEmpty).toList() : [text];
    if (text.isEmpty) {
      setState(() => _error = widget.optional ? null : '시리얼을 입력해 주세요.');
      return widget.optional;
    }
    bool valid = true;
    final repo = context.read<InventoryRepository>();
    final loaded = await runGuarded(context, () async {
      for (final serial in serials) {
        bool found = false;
        int pageNo = 1;
        while (true) {
          final page = await repo.list(query: serial, categoryId: widget.categoryId, size: 20, page: pageNo++);
          found = page.items.any((a) => a.serialNo?.trim().toLowerCase() == serial.toLowerCase());
          if (found || !page.hasMore) break;
        }
        if (!found) valid = false;
      }
    });
    if (!mounted || revision != _revision || validation != _validation) return false;
    setState(() => _error = !loaded ? '재고 확인에 실패했습니다. 다시 시도해 주세요.'
      : valid ? null : '재고에 등록되지 않은 S/N 입니다');
    if (loaded && !valid && notify) showRegistrationHint();
    return loaded && valid;
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<String>(
    textEditingController: widget.controller, focusNode: _focus,
    optionsBuilder: (value) async {
      final revision = _revision;
      final repo = context.read<InventoryRepository>();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || revision != _revision) return const <String>[];
      final parts = widget.multiple ? value.text.split(RegExp(r'[,;/\s]+')) : [value.text];
      final query = parts.last.trim();
      if (query.isEmpty) return const <String>[];
      final prefix = widget.multiple ? value.text.substring(0, value.text.length - parts.last.length) : '';
      try {
        final page = await repo.list(query: query, categoryId: widget.categoryId, size: 20);
        if (!mounted || revision != _revision) return const <String>[];
        return page.items.map((a) => a.serialNo).whereType<String>()
          .where((s) => s.isNotEmpty).map((s) => '$prefix$s').toSet();
      } catch (_) { return const <String>[]; }
    },
    onSelected: (_) => validate(),
    fieldViewBuilder: (context, controller, focus, submit) => TextFormField(
      controller: controller, focusNode: focus, onFieldSubmitted: (_) => submit(),
      decoration: InputDecoration(labelText: widget.label, errorText: _error,
        helperText: widget.helperText ?? '재고에 있는 S/N 만 · 다른 매장에 있던 장비는 이 매장으로 옮겨집니다', helperMaxLines: 3),
      validator: (v) => !widget.optional && (v == null || v.trim().isEmpty) ? '시리얼을 입력해 주세요.' : null,
    ),
    optionsViewBuilder: (context, select, options) => Align(alignment: Alignment.topLeft,
      child: Material(elevation: 4, child: SizedBox(width: 280, height: 200,
        child: ListView(padding: EdgeInsets.zero, children: [for (final serial in options)
          ListTile(title: Text(serial), onTap: () => select(serial))])))),
  );
}
