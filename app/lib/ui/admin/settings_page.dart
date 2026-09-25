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
              const SizedBox(height: AppSpace.md),
              for (final group in data.codeGroups)
                Padding(
                  key: ValueKey(group.id),
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _CodeGroupCard(
                    group: group,
                    parentGroup: data.codeGroups.where(
                        (g) => g.code == group.parentGroupCode).firstOrNull,
                    childGroups: data.codeGroups.where(
                        (g) => g.parentGroupCode == group.code).toList(),
                    onChanged: reload,
                  ),
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

class _CodeGroupCard extends StatefulWidget {
  const _CodeGroupCard({required this.group, required this.parentGroup,
    required this.childGroups, required this.onChanged});

  final CodeGroup group;
  final CodeGroup? parentGroup;
  final List<CodeGroup> childGroups;
  final VoidCallback onChanged;

  @override
  State<_CodeGroupCard> createState() => _CodeGroupCardState();
}

class _CodeGroupCardState extends State<_CodeGroupCard> {
  final Map<String, TextEditingController> _newItems = {};
  bool _busy = false;
  CodeGroup get group => widget.group;
  CodeGroup? get parentGroup => widget.parentGroup;
  VoidCallback get onChanged => widget.onChanged;

  @override
  void dispose() {
    for (final controller in _newItems.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _nextCode(String prefix) {
    final codes = group.items.map((item) => item.code).toSet();
    var n = 1;
    while (codes.contains('${prefix}_${n.toString().padLeft(2, '0')}')) {
      n++;
    }
    return '${prefix}_${n.toString().padLeft(2, '0')}';
  }

  List<List<CodeItem>> _sections() {
    if (parentGroup == null) return [group.items.toList()];
    final parentIds = parentGroup!.items.map((p) => p.id).toSet();
    return [
      for (final parent in parentGroup!.items)
        group.items.where((item) => item.parentId == parent.id).toList(),
      group.items.where((item) => !parentIds.contains(item.parentId)).toList(),
    ];
  }

  Future<void> _move(CodeItem item, int offset) async {
    if (_busy) return;
    final sections = _sections();
    final section = sections.firstWhere((items) => items.any((i) => i.id == item.id));
    final index = section.indexWhere((i) => i.id == item.id);
    final target = index + offset;
    if (target < 0 || target >= section.length) return;
    section[index] = section[target];
    section[target] = item;
    setState(() => _busy = true);
    final ok = await runGuarded(context, () => context.read<AdminRepository>()
        .reorderCodeItems(group.id, [for (final items in sections) ...items.map((i) => i.id)]));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) onChanged();
  }

  Future<void> _addChild(CodeItem parent, TextEditingController controller) async {
    final name = controller.text.trim();
    if (_busy || name.isEmpty) return;
    setState(() => _busy = true);
    final ok = await runGuarded(context, () => context.read<AdminRepository>().addCodeItem(
      group.id, code: _nextCode(parent.code), name: name,
      parentId: parent.id, sortOrder: group.items.length + 1));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      controller.clear();
      onChanged();
    }
  }

  Widget _parentField(String? value, ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: '${parentGroup!.name} *'),
      items: [for (final parent in parentGroup!.items)
        DropdownMenuItem(value: parent.id,
          child: Text('${parent.name}${parent.isActive ? '' : ' (사용 안 함)'}',
            overflow: TextOverflow.ellipsis)),
      ],
      validator: (id) => id == null ? '상위 분류를 선택해 주세요' : null,
      onChanged: onChanged,
    );
  }

  Widget? _subtitle(BuildContext context, CodeItem item, bool unassigned) {
    final children = <String>[];
    for (final child in widget.childGroups) {
      final count = child.items.where((i) => i.parentId == item.id).length;
      if (count > 0) children.add('${child.name} $count');
    }
    final lines = [
      if (!item.isActive) '사용 안 함',
      if (unassigned) '⋮ › 상위 변경에서 상위를 지정하세요',
      if (parentGroup == null && item.isActive && item.code != item.name) item.code,
      if (children.isNotEmpty) '하위: ${children.join(' · ')}',
    ];
    return lines.isEmpty ? null : Text(lines.join('\n'));
  }

  Widget _itemRow(CodeItem item, List<CodeItem> items, {bool unassigned = false}) {
    final index = items.indexOf(item);
    final canUp = !_busy && index > 0;
    final canDown = !_busy && index < items.length - 1;
    return LayoutBuilder(builder: (context, constraints) {
      final menuArrows = !AppTheme.isWide(context) && constraints.maxWidth < 400;
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        minLeadingWidth: 14,
        horizontalTitleGap: 8,
        title: Row(children: [
          Flexible(child: Text(item.name, style: TextStyle(
            color: item.isActive ? null : Theme.of(context).colorScheme.outline))),
          if (item.isProtected) ...[
            const SizedBox(width: 4),
            const Tooltip(message: '재고 상태 규칙에 쓰이는 항목',
              child: Icon(Icons.lock_outline, size: 14)),
          ],
        ]),
        subtitle: _subtitle(context, item, unassigned),
        leading: item.color == null ? null : CircleAvatar(radius: 7, backgroundColor: parseHexColor(item.color!)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (!menuArrows) ...[
            IconButton(tooltip: '위로', iconSize: 20,
              constraints: const BoxConstraints.tightFor(width: 32, height: 40),
              padding: EdgeInsets.zero,
              onPressed: canUp ? () => _move(item, -1) : null,
              icon: const Icon(Icons.arrow_upward)),
            IconButton(tooltip: '아래로', iconSize: 20,
              constraints: const BoxConstraints.tightFor(width: 32, height: 40),
              padding: EdgeInsets.zero,
              onPressed: canDown ? () => _move(item, 1) : null,
              icon: const Icon(Icons.arrow_downward)),
          ],
          PopupMenuButton<String>(
            tooltip: '항목 관리',
            enabled: !_busy,
            icon: const Icon(Icons.more_vert),
            onSelected: (action) async {
              switch (action) {
                case 'up':
                  await _move(item, -1);
                  break;
                case 'down':
                  await _move(item, 1);
                  break;
                case 'edit':
                  await _editItem(context, item);
                  break;
                case 'parent':
                  await _changeParent(context, item);
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
              const PopupMenuItem(value: 'edit', child: Text('이름 바꾸기')),
              if (parentGroup != null)
                const PopupMenuItem(value: 'parent', child: Text('상위 변경')),
              PopupMenuItem(value: 'active', child: Text(item.isActive ? '사용 안 함' : '다시 사용')),
              PopupMenuItem(value: 'delete', enabled: !item.isProtected,
                child: Text('삭제', style: TextStyle(color: item.isProtected
                    ? Theme.of(context).disabledColor : AppColors.danger(context)))),
              if (menuArrows) ...[
                PopupMenuItem(value: 'up', enabled: canUp, child: const Text('위로')),
                PopupMenuItem(value: 'down', enabled: canDown, child: const Text('아래로')),
              ],
            ],
          ),
        ]),
      );
    });
  }

  Widget _parentSection(CodeItem? parent, List<CodeItem> items) {
    final colors = Theme.of(context).colorScheme;
    final controller = parent == null ? null : _newItems.putIfAbsent(
        parent.id, () => TextEditingController());
    return Container(
      decoration: BoxDecoration(border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.all(10), child: Row(children: [
          Flexible(child: Text(parent == null ? '상위 미지정'
              : '${parent.name}${parent.isActive ? '' : ' (사용 안 함)'}',
            style: TextStyle(fontWeight: FontWeight.w600,
              color: parent == null ? colors.error : null))),
          const SizedBox(width: 8),
          Text('${items.length}', style: TextStyle(fontSize: 12, color: colors.outline)),
        ])),
        const Divider(height: 1),
        if (items.isEmpty) Padding(padding: const EdgeInsets.all(12),
          child: Text('항목 없음', style: TextStyle(color: colors.outline))),
        for (final item in items) _itemRow(item, items, unassigned: parent == null),
        if (parent != null && controller != null)
          Padding(padding: const EdgeInsets.all(8), child: Row(children: [
            Expanded(child: TextField(controller: controller, enabled: !_busy,
              decoration: const InputDecoration(hintText: '새 항목'),
              onSubmitted: (_) => _addChild(parent, controller))),
            const SizedBox(width: 8),
            TextButton(onPressed: _busy ? null : () => _addChild(parent, controller),
              child: const Text('추가')),
          ])),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections();
    final parents = parentGroup?.items ?? const <CodeItem>[];
    final wide = AppTheme.isWide(context);
    return SectionCard(title: group.name, actions: [
      if (parentGroup == null)
        TextButton.icon(onPressed: _busy ? null : () => _addItem(context),
          icon: const Icon(Icons.add), label: const Text('항목 추가')),
    ], child: parentGroup == null ? Column(children: [
      if (group.items.isEmpty) const EmptyState(message: '아직 등록된 코드 항목이 없습니다'),
      for (final item in group.items) _itemRow(item, group.items),
    ]) : Padding(padding: const EdgeInsets.all(12), child: Wrap(
      spacing: 12, runSpacing: 12,
      children: [
        for (var i = 0; i < parents.length; i++)
          SizedBox(width: wide ? 320 : double.infinity,
            child: _parentSection(parents[i], sections[i])),
        if (sections.last.isNotEmpty)
          SizedBox(width: wide ? 320 : double.infinity,
            child: _parentSection(null, sections.last)),
      ],
    )));
  }

  Future<void> _changeParent(BuildContext context, CodeItem item) async {
    if (parentGroup == null) return;
    final formKey = GlobalKey<FormState>();
    var parentId = parentGroup!.items.where((p) => p.id == item.parentId).firstOrNull?.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ConfirmDialog.form(
        title: Text("'${item.name}' 상위 변경"),
        content: Form(key: formKey, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _parentField(parentId, (id) => parentId = id),
            const SizedBox(height: AppSpace.md),
            const Text('이 항목을 쓰는 기존 기록은 그대로 두고, 새로 등록할 때의 선택지만 바뀝니다.'),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
          FilledButton(onPressed: () {
            if (formKey.currentState!.validate()) Navigator.of(ctx).pop(true);
          }, child: const Text('저장')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted ||
        parentId == null || parentId == item.parentId) return;
    final parentName = parentGroup!.items.where((p) => p.id == parentId).first.name;
    final ok = await runGuarded(context, () async {
      await context.read<AdminRepository>().updateCodeItem(
        item.id, {'parent_id': parentId});
    });
    if (!ok || !context.mounted) return;
    onChanged();
    if (!context.mounted) return;
    AppSnack.show(context, "'${item.name}' 을(를) '$parentName' 아래로 옮겼습니다");
  }

  Future<void> _addItem(BuildContext context) async {
    final formKey = GlobalKey<FormState>();
    final code = TextEditingController();
    final name = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ConfirmDialog.form(
        title: Text('${group.name} 항목 추가'),
        content: Form(key: formKey, child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: code,
              decoration: const InputDecoration(
                labelText: '코드',
                helperText: '비우면 자동으로 만듭니다',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: AppSpace.md),
            TextFormField(
              controller: name,
              decoration: const InputDecoration(labelText: '표시 이름 *'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? '이름을 입력해 주세요' : null,
            ),
          ],
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.of(ctx).pop(true);
            },
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        name.text.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    final ok = await runGuarded(
      context,
      () => context.read<AdminRepository>().addCodeItem(
            group.id,
            code: code.text.trim().isEmpty ? _nextCode(group.code) : code.text.trim().toUpperCase(),
            name: name.text.trim(),
            sortOrder: group.items.length + 1,
          ),
      successMessage: '항목이 추가되었습니다.',
    );
    if (!ok || !context.mounted) return;
    onChanged();
  }

  Future<void> _editItem(BuildContext context, CodeItem item) async {
    final formKey = GlobalKey<FormState>();
    var name = item.name;
    var color = item.color;
    var parentId = parentGroup?.items.where((p) => p.id == item.parentId).firstOrNull?.id;
    const palette = [
      ('파랑', '#3B82F6'), ('하늘', '#0EA5E9'),
      ('청록', '#14B8A6'), ('초록', '#22C55E'),
      ('노랑', '#EAB308'), ('주황', '#F97316'),
      ('빨강', '#EF4444'), ('보라', '#8B5CF6'),
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => ConfirmDialog.form(
        title: const Text('이름 바꾸기'),
        content: Form(key: formKey, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parentGroup != null) ...[
              _parentField(parentId, (id) => setState(() => parentId = id)),
              const SizedBox(height: AppSpace.md),
            ],
            TextFormField(
              initialValue: name,
              decoration: const InputDecoration(labelText: '표시 이름 *'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? '이름을 입력해 주세요' : null,
              onChanged: (value) => name = value,
            ),
            const FormGap(),
            const Text('표시 색 (선택)'),
            const FormGap(),
            Wrap(spacing: 8, runSpacing: AppSpace.md, children: [
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
        if (parentGroup != null) 'parent_id': parentId,
      });
    });
    if (!ok || !context.mounted) return;
    onChanged();
    AppSnack.show(context, '저장되었습니다');
  }

  Future<void> _setActive(BuildContext context, CodeItem item) async {
    if (item.isActive) {
      final confirmed = await ConfirmDialog.show(context,
        title: '${item.name} 사용 안 함',
        message: '드롭다운에서 빠질 뿐, 이미 입력된 기록은 그대로 남습니다.',
        confirmLabel: '사용 안 함');
      if (!confirmed || !context.mounted) return;
    }
    final ok = await runGuarded(context, () async {
      await context.read<AdminRepository>().updateCodeItem(
        item.id, {'is_active': !item.isActive});
    });
    if (!ok || !context.mounted) return;
    onChanged();
    AppSnack.show(context, item.isActive ? '사용 안 함으로 변경되었습니다.' : '다시 사용할 수 있습니다.');
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
