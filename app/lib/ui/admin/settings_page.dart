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
part 'code_group_card.dart';

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
    return DirtyFormScope(
      busy: _saving,
      isDirty: () => _dirty,
      child: Scaffold(
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
        body: PageBody(
          child: AsyncView<ModuleSettings>(
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
                    SectionCard(
                      title: '설정 항목',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        child: Column(
                          children: [
                            for (final s in data.settings)
                              SettingRow(
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
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
                          parentGroup: data.codeGroups
                              .where((g) => g.code == group.parentGroupCode)
                              .firstOrNull,
                          childGroups: data.codeGroups
                              .where((g) => g.parentGroupCode == group.code)
                              .toList(),
                          onChanged: reload,
                        ),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
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
      () =>
          context.read<AdminRepository>().saveSettings(widget.module, _loaded),
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

/// 설정 한 줄. 편집기는 `value_type` 으로 고르고, 입력은 [setting] 에 바로
/// 반영한 뒤 [onChanged] 로 부모에 알린다. 위젯 테스트에서 단독으로 띄울 수
/// 있도록 공개해 두었다.
class SettingRow extends StatefulWidget {
  const SettingRow({super.key, required this.setting, required this.onChanged});

  final ModuleSetting setting;
  final VoidCallback onChanged;

  @override
  State<SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<SettingRow> {
  // 컨트롤러는 한 번만 만든다. build 마다 새로 만들면 부모가 리빌드될 때마다
  // 입력이 정규화값으로 되돌아가서(쉼표가 사라지고 커서가 끝으로 튐) 타이핑이
  // 불가능해진다.
  late final TextEditingController _controller = TextEditingController(
    text: _textFor(widget.setting),
  );
  final _focus = FocusNode();

  static String _textFor(ModuleSetting s) =>
      s.valueType == 'list' ? s.asStringList.join(', ') : s.asText;

  @override
  void didUpdateWidget(SettingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 저장 뒤 서버 재조회처럼 바깥에서 값이 바뀌면 따라가되, 입력 중(포커스)
    // 에는 사용자가 친 글자를 그대로 둔다.
    if (_focus.hasFocus) return;
    final text = _textFor(widget.setting);
    if (_controller.text != text) _controller.text = text;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
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
          focusNode: _focus,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          decoration: const InputDecoration(isDense: true),
          onChanged: (v) {
            s.setFromInput(v);
            widget.onChanged();
          },
        ),
      ),
      // 구조가 있는 값은 글자로 고치면 깨진다. 전용 화면에서만 편집한다.
      'json' => Text(
        '전용 화면에서 편집',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      'list' => SizedBox(
        width: 200,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          decoration: const InputDecoration(isDense: true, hintText: '쉼표로 구분'),
          onChanged: (v) {
            s.setFromInput(
              v
                  .split(',')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList(),
            );
            widget.onChanged();
          },
        ),
      ),
      _ => SizedBox(
        width: 200,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
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
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: AppTheme.isWide(context)
          ? Row(
              children: [
                Expanded(child: label),
                const SizedBox(width: AppSpace.md),
                editor,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                label,
                const FormGap(),
                Align(alignment: Alignment.centerRight, child: editor),
              ],
            ),
    );
  }
}
