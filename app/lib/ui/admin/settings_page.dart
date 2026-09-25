import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

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
      body: PageBody(child: AsyncView<ModuleSettings>(
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
              const EmptyState(message: '아직 등록된 설정 항목이 없습니다')
            else
              SectionCard(title: '설정 항목',
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
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
      )),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
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

    final label = Column(
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
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            );
    return Padding(padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: AppTheme.isWide(context)
        ? Row(children: [Expanded(child: label), const SizedBox(width: AppSpace.md), editor])
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            label, const FormGap(), Align(alignment: Alignment.centerRight, child: editor),
          ]));
  }
}

class _CodeGroupCard extends StatelessWidget {
  const _CodeGroupCard({required this.group, required this.onChanged});

  final CodeGroup group;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SectionCard(title: group.name, actions: [
      TextButton.icon(onPressed: () => _addItem(context), icon: const Icon(Icons.add), label: const Text('항목 추가')),
    ], child: Column(children: [
      if (group.items.isEmpty) const EmptyState(message: '아직 등록된 코드 항목이 없습니다'),
      for (final item in group.items) ListTile(
        title: Row(children: [
          Flexible(child: Text(item.name, style: TextStyle(
            color: item.isActive ? null : Theme.of(context).colorScheme.outline))),
          if (item.isProtected) ...[
            const SizedBox(width: 4),
            const Tooltip(message: '재고 상태 규칙에 쓰이는 항목',
              child: Icon(Icons.lock_outline, size: 14)),
          ],
        ]),
        subtitle: !item.isActive
            ? const Text('비활성 · 새 등록 때 선택 안 됨')
            : item.code != item.name ? Text(item.code) : null,
        leading: item.color == null ? null : CircleAvatar(radius: 7, backgroundColor: parseHexColor(item.color!)),
        trailing: PopupMenuButton<String>(
          tooltip: '항목 관리',
          icon: const Icon(Icons.more_vert),
          onSelected: (action) async {
            switch (action) {
              case 'edit':
                await _editItem(context, item);
                break;
              case 'active':
                await _setActive(context, item);
                break;
              case 'delete':
                await _deleteItem(context, item);
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('이름·색 수정')),
            PopupMenuItem(value: 'active', child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.isActive ? '비활성화' : '다시 사용'),
                if (item.isActive) const Text(
                  '새로 등록할 때 선택지에서만 빠집니다. 목록에는 남습니다.',
                  style: TextStyle(fontSize: 12)),
              ],
            )),
            PopupMenuItem(value: 'delete', enabled: !item.isProtected,
              child: Row(children: [
                Icon(Icons.delete_outline, color: item.isProtected
                    ? Theme.of(context).disabledColor : AppColors.danger(context)),
                const SizedBox(width: 8),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('삭제', style: TextStyle(color: item.isProtected
                        ? Theme.of(context).disabledColor : AppColors.danger(context))),
                    if (item.isProtected) const Text('재고 상태 규칙에 쓰이는 항목',
                      style: TextStyle(fontSize: 12)),
                  ],
                )),
              ])),
          ],
        ),
      ),
    ]));
  }

  Future<void> _addItem(BuildContext context) async {
    final code = TextEditingController();
    final name = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ConfirmDialog.form(
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

  Future<void> _editItem(BuildContext context, CodeItem item) async {
    final formKey = GlobalKey<FormState>();
    var name = item.name;
    var color = item.color;
    const palette = [
      ('파랑', '#3B82F6'), ('하늘', '#0EA5E9'),
      ('청록', '#14B8A6'), ('초록', '#22C55E'),
      ('노랑', '#EAB308'), ('주황', '#F97316'),
      ('빨강', '#EF4444'), ('보라', '#8B5CF6'),
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => ConfirmDialog.form(
        title: const Text('이름·색 수정'),
        content: Form(key: formKey, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              initialValue: name,
              decoration: const InputDecoration(labelText: '표시 이름 *'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? '이름을 입력해 주세요' : null,
              onChanged: (value) => name = value,
            ),
            const SizedBox(height: 16),
            const Text('표시 색 (선택)'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(label: const Text('없음'), selected: color == null,
                onSelected: (_) => setState(() => color = null)),
              for (final (label, hex) in palette)
                ChoiceChip(
                  label: Text(label),
                  avatar: CircleAvatar(backgroundColor: parseHexColor(hex), radius: 7),
                  selected: color?.toUpperCase() == hex,
                  onSelected: (_) => setState(() => color = hex),
                ),
              if (item.color != null &&
                  !palette.any((entry) => entry.$2 == item.color!.toUpperCase()))
                ChoiceChip(label: const Text('기존 색'),
                  avatar: CircleAvatar(backgroundColor: parseHexColor(item.color!), radius: 7),
                  selected: color == item.color,
                  onSelected: (_) => setState(() => color = item.color)),
            ]),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
          FilledButton(onPressed: () {
            if (formKey.currentState!.validate()) Navigator.of(ctx).pop(true);
          }, child: const Text('저장')),
        ],
      )),
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await runGuarded(context, () async {
      await context.read<AdminRepository>().updateCodeItem(item.id, {
        'name': name.trim(),
        'color': color,
      });
    });
    if (!ok || !context.mounted) return;
    onChanged();
    AppSnack.show(context, '저장되었습니다');
  }

  Future<void> _setActive(BuildContext context, CodeItem item) async {
    if (item.isActive) {
      final confirmed = await ConfirmDialog.show(context,
        title: '${item.name} 비활성화',
        message: '새로 등록할 때 선택지에서만 빠집니다. 목록에는 남습니다.',
        confirmLabel: '비활성화');
      if (!confirmed || !context.mounted) return;
    }
    final ok = await runGuarded(context, () async {
      await context.read<AdminRepository>().updateCodeItem(
        item.id, {'is_active': !item.isActive});
    });
    if (!ok || !context.mounted) return;
    onChanged();
    AppSnack.show(context, item.isActive ? '비활성화되었습니다.' : '다시 사용할 수 있습니다.');
  }

  Future<void> _deleteItem(BuildContext context, CodeItem item) async {
    if (item.isProtected) return;
    final repo = context.read<AdminRepository>();
    late CodeItemUsage usage;
    final loaded = await runGuarded(context, () async {
      usage = await repo.codeItemUsage(item.id);
    });
    if (!loaded || !context.mounted) return;
    if (usage.isProtected) {
      AppSnack.show(context, usage.protectedReason ?? '재고 상태 규칙에 쓰이는 항목', error: true);
      return;
    }
    final breakdown = usage.by.entries.map((entry) => '${entry.key} ${entry.value}').join(' · ');
    final message = [
      usage.count == 0 ? '이 항목을 쓰는 기록이 없습니다'
          : '이 항목을 쓰는 기록 ${usage.count}건${breakdown.isEmpty ? '' : ' ($breakdown)'}',
      if (usage.children > 0) '하위 항목 ${usage.children}개도 함께 삭제됩니다.',
      '삭제해도 기존 기록의 분류 이름은 그대로 남습니다. 같은 코드로 다시 추가하면 되살아납니다.',
    ].join('\n\n');
    final confirmed = await ConfirmDialog.show(context,
      title: '${item.name} 삭제', message: message,
      confirmLabel: '삭제', destructive: true);
    if (!confirmed || !context.mounted) return;

    late String result;
    final ok = await runGuarded(context, () async {
      result = await repo.deleteCodeItem(item.id);
    });
    if (!ok || !context.mounted) return;
    onChanged();
    AppSnack.show(context, result);
  }
}
