import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../models/admin.dart';
import '../../models/calendar.dart' show parseHexColor;
import '../../models/common.dart';
import '../async_view.dart';
import '../theme.dart';

/// The one settings screen that serves all six modules.
///
/// Nothing here is module-specific: the widget for each row is chosen from the
/// server's `value_type`, and the classification editor below is driven by the
/// `code_groups` the same response carries. Adding a setting on the server
/// makes it appear here with no client change.
class ModuleSettingsPage extends StatefulWidget {
  const ModuleSettingsPage({super.key, required this.module});
  final SettingsModule module;

  @override
  State<ModuleSettingsPage> createState() => _ModuleSettingsPageState();
}

class _ModuleSettingsPageState extends State<ModuleSettingsPage> {
  final _viewKey = GlobalKey<AsyncViewState<ModuleSettings>>();
  bool _saving = false;
  bool _dirty = false;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AdminRepository>();
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.module.label} 설정'),
        actions: [
          if (_dirty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  '변경됨',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: AsyncView<ModuleSettings>(
        key: _viewKey,
        load: () => repo.settings(widget.module),
        builder: (context, data, reload) {
          // The row editors mutate these ModuleSetting objects in place, so
          // holding the loaded list is all the save button needs.
          _loaded = data.settings;
          return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            if (data.settings.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('이 모듈에는 설정 항목이 없습니다.'),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  child: Column(
                    children: [
                      for (final s in data.settings)
                        _SettingRow(
                          setting: s,
                          onChanged: () => setState(() => _dirty = true),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 18),
            if (data.codeGroups.isNotEmpty) ...[
              Text(
                '분류 항목 관리',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '여기서 바꾼 항목이 접수 화면의 선택지와 통계 분류에 그대로 반영됩니다.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              const SizedBox(height: 10),
              for (final group in data.codeGroups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _CodeGroupCard(group: group, onChanged: reload),
                ),
            ],
          ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _saving ? null : () => _save(),
            icon: _saving
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('설정 저장'),
          ),
        ),
      ),
    );
  }

  /// Settings currently on screen. Populated by the AsyncView builder.
  List<ModuleSetting> _loaded = [];

  Future<void> _save() async {
    final view = _viewKey.currentState;
    if (view == null || _loaded.isEmpty) return;

    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => context
          .read<AdminRepository>()
          .saveSettings(widget.module, _loaded),
      successMessage: '설정이 저장되었습니다.',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _dirty = false;
    });
    if (ok) view.reload();
  }
}

class _SettingRow extends StatefulWidget {
  const _SettingRow({required this.setting, required this.onChanged});

  final ModuleSetting setting;
  final VoidCallback onChanged;

  @override
  State<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<_SettingRow> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.setting.asText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.setting;
    final scheme = Theme.of(context).colorScheme;

    // The widget is picked from value_type, never from the key name.
    final editor = switch (s.valueType) {
      'bool' => Switch(
          value: s.asBoolean,
          onChanged: (v) => setState(() {
            s.setFromInput(v);
            widget.onChanged();
          }),
        ),
      'int' || 'float' => SizedBox(
          width: 110,
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.right,
            decoration: const InputDecoration(isDense: true),
            onChanged: (v) {
              s.setFromInput(v);
              widget.onChanged();
            },
          ),
        ),
      'list' => SizedBox(
          width: 200,
          child: TextField(
            controller: TextEditingController(
                text: s.asStringList.join(', ')),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '쉼표로 구분',
            ),
            onChanged: (v) {
              s.setFromInput(v
                  .split(',')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList());
              widget.onChanged();
            },
          ),
        ),
      _ => SizedBox(
          width: 200,
          child: TextField(
            controller: _controller,
            decoration: const InputDecoration(isDense: true),
            onChanged: (v) {
              s.setFromInput(v);
              widget.onChanged();
            },
          ),
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        s.displayLabel,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (!s.isPublic) ...[
                      const SizedBox(width: 6),
                      const StatusChip(
                        label: '관리자',
                        color: Color(0xFF94A3B8),
                        dense: true,
                      ),
                    ],
                  ],
                ),
                Text(
                  s.description ?? s.key,
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          editor,
        ],
      ),
    );
  }
}

class _CodeGroupCard extends StatelessWidget {
  const _CodeGroupCard({required this.group, required this.onChanged});

  final CodeGroup group;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    group.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _addItem(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('항목 추가'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (group.items.isEmpty)
              const Text('등록된 항목이 없습니다.', style: TextStyle(fontSize: 12))
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final item in group.items)
                    InputChip(
                      label: Text(
                        item.name,
                        style: TextStyle(
                          fontSize: 12,
                          decoration: item.isActive
                              ? null
                              : TextDecoration.lineThrough,
                        ),
                      ),
                      avatar: item.color != null
                          ? CircleAvatar(
                              backgroundColor: parseHexColor(item.color!),
                              radius: 7,
                            )
                          : null,
                      // Deleting deactivates rather than removes, so existing
                      // tickets and their statistics keep resolving the name.
                      onDeleted: item.isActive
                          ? () => _deactivate(context, item)
                          : null,
                      deleteIcon: const Icon(Icons.close, size: 14),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _addItem(BuildContext context) async {
    final code = TextEditingController();
    final name = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${group.name} 항목 추가'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: code,
              decoration: const InputDecoration(
                labelText: '코드 *',
                helperText: '영문 대문자 권장 (예: EMERGENCY)',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '표시 이름 *'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        code.text.trim().isEmpty ||
        name.text.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    final ok = await runGuarded(
      context,
      () => context.read<AdminRepository>().addCodeItem(
            group.id,
            code: code.text.trim().toUpperCase(),
            name: name.text.trim(),
            sortOrder: group.items.length + 1,
          ),
      successMessage: '항목이 추가되었습니다.',
    );
    if (ok) onChanged();
  }

  Future<void> _deactivate(BuildContext context, CodeItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${item.name} 비활성화'),
        content: const Text(
          '새로 등록할 때 선택지에서 제외됩니다.\n'
          '기존 데이터의 분류와 통계는 그대로 유지됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('비활성화'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await runGuarded(
      context,
      () => context.read<AdminRepository>().deleteCodeItem(item.id),
      successMessage: '비활성화되었습니다.',
    );
    if (ok) onChanged();
  }
}
