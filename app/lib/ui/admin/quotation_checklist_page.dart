import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../models/admin.dart';
import '../../models/quotation.dart';
import '../async_view.dart';
import '../common/common.dart';

const _settingKey = 'quotation_checklist';

/// 견적서 체크리스트 관리. 항목마다 체크했을 때 채울 안내사항과 품목을 정한다.
class QuotationChecklistPage extends StatefulWidget {
  const QuotationChecklistPage({super.key});

  @override
  State<QuotationChecklistPage> createState() => _QuotationChecklistPageState();
}

class _QuotationChecklistPageState extends State<QuotationChecklistPage> {
  ModuleSetting? _setting;
  List<QuoteChecklistEntry> _entries = [];
  bool _dirty = false;
  bool _busy = false;

  Future<List<QuoteChecklistEntry>> _load() async {
    final settings = await context.read<AdminRepository>().settings(
      SettingsModule.service,
    );
    _setting = settings.settings.where((s) => s.key == _settingKey).firstOrNull;
    _entries = [
      for (final e in _setting?.value as List? ?? const [])
        QuoteChecklistEntry.fromJson(Map<String, dynamic>.from(e as Map)),
    ];
    _dirty = false;
    return _entries;
  }

  void _change(VoidCallback update) => setState(() {
    update();
    _dirty = true;
  });

  Future<void> _edit([int? index]) async {
    final edited = await Navigator.of(context).push<QuoteChecklistEntry>(
      MaterialPageRoute(
        builder: (_) => _EntryEditor(
          entry: index == null
              ? QuoteChecklistEntry(
                  id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
                  label: '',
                )
              : _entries[index],
        ),
      ),
    );
    if (edited == null || !mounted) return;
    _change(() {
      if (index == null) {
        _entries.add(edited);
      } else {
        _entries[index] = edited;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final setting =
        _setting ??
        ModuleSetting(
          key: _settingKey,
          valueType: 'json',
          value: null,
          label: '견적서 체크리스트 (견적서 화면에서 편집)',
        );
    final previous = setting.value;
    setting.value = [for (final e in _entries) e.toJson()];
    final ok = await runGuarded(
      context,
      () => context.read<AdminRepository>().saveSettings(
        SettingsModule.service,
        [setting],
      ),
      successMessage: '견적서 체크리스트를 저장했습니다.',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _setting = setting;
        _dirty = false;
      } else {
        setting.value = previous;
      }
    });
  }

  @override
  Widget build(BuildContext context) => DirtyFormScope(
    busy: _busy,
    isDirty: () => _dirty,
    child: Scaffold(
      appBar: AppBar(title: const Text('견적서 체크리스트')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-checklist',
        onPressed: _busy || _entries.length >= 50 ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('항목 추가'),
      ),
      body: PageBody(
        child: AsyncView<List<QuoteChecklistEntry>>(
          load: _load,
          builder: (context, _, reload) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '견적서 작성 화면에서 체크하면 안내사항에 문구가, 품목에 견적 품목이 '
                '자동으로 추가됩니다. 끌어서 순서를 바꿀 수 있습니다.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _entries.isEmpty
                    ? const EmptyState(
                        icon: Icons.checklist,
                        message: '등록된 체크리스트 항목이 없습니다',
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.only(bottom: 90),
                        itemCount: _entries.length,
                        onReorderItem: (from, to) => _change(
                          () => _entries.insert(to, _entries.removeAt(from)),
                        ),
                        itemBuilder: (context, i) {
                          final e = _entries[i];
                          return Card(
                            key: ValueKey(e.id),
                            child: ListTile(
                              title: Text(e.label),
                              subtitle: Text(
                                [
                                  if (e.notes.isNotEmpty)
                                    e.notes.split('\n').first,
                                  if (e.items.isNotEmpty)
                                    '품목 ${e.items.length}개',
                                  if (!e.active) '사용 안 함',
                                ].join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: _busy ? null : () => _edit(i),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: e.active,
                                    onChanged: _busy
                                        ? null
                                        : (v) => _change(
                                            () => _entries[i] = e.copyWith(
                                              active: v,
                                            ),
                                          ),
                                  ),
                                  IconButton(
                                    tooltip: '삭제',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: _busy
                                        ? null
                                        : () async {
                                            if (await ConfirmDialog.show(
                                                  context,
                                                  title: '체크리스트 항목 삭제',
                                                  message:
                                                      "'${e.label}'을(를) 삭제합니다. 이미 저장된 견적서에는 영향이 없습니다.",
                                                  confirmLabel: '삭제',
                                                  destructive: true,
                                                ) &&
                                                mounted) {
                                              _change(
                                                () => _entries.removeWhere(
                                                  (x) => x.id == e.id,
                                                ),
                                              );
                                            }
                                          },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              FormActions(
                child: FilledButton(
                  onPressed: _busy || !_dirty ? null : _save,
                  child: Text(_busy ? '저장 중…' : '저장'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 체크리스트 항목 하나: 이름, 채울 안내사항, 추가할 품목.
class _EntryEditor extends StatefulWidget {
  const _EntryEditor({required this.entry});
  final QuoteChecklistEntry entry;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.entry.label);
  late final _notes = TextEditingController(text: widget.entry.notes);
  late final List<Map<String, TextEditingController>> _items = [
    for (final item in widget.entry.items) _controllers(item),
  ];

  static Map<String, TextEditingController> _controllers(
    Map<String, String> item,
  ) => {
    for (final k in QuoteChecklistEntry.itemKeys)
      k: TextEditingController(text: item[k] ?? (k == 'quantity' ? '1' : '')),
  };

  @override
  void dispose() {
    _label.dispose();
    _notes.dispose();
    for (final item in _items) {
      for (final c in item.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _done() {
    if (!_form.currentState!.validate()) return;
    final items = [
      for (final item in _items)
        {for (final e in item.entries) e.key: e.value.text.trim()},
    ];
    if (_notes.text.trim().isEmpty && items.isEmpty) {
      AppSnack.show(context, '채울 안내사항이나 품목을 하나 이상 입력하세요.', error: true);
      return;
    }
    Navigator.of(context).pop(
      widget.entry.copyWith(
        label: _label.text.trim(),
        notes: _notes.text.trim(),
        items: items,
      ),
    );
  }

  String? _required(String? v) =>
      v == null || v.trim().isEmpty ? '입력해 주세요.' : null;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.entry.label.isEmpty ? '체크리스트 항목 추가' : '체크리스트 항목 수정'),
    ),
    body: PageBody(
      child: Form(
        key: _form,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                children: [
                  TextFormField(
                    controller: _label,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      labelText: '이름 *',
                      hintText: '예: 레인보우 입고',
                    ),
                    validator: _required,
                  ),
                  const FormGap(),
                  TextFormField(
                    controller: _notes,
                    maxLength: 1000,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: '체크 시 안내사항에 추가할 문구',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const FormGap(),
                  Text(
                    '체크 시 추가할 품목',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final (i, item) in _items.indexed)
                    Card(
                      key: ObjectKey(item),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(child: Text('품목 ${i + 1}')),
                                IconButton(
                                  tooltip: '품목 빼기',
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    final removed = _items[i];
                                    setState(() => _items.removeAt(i));
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          for (final c in removed.values) {
                                            c.dispose();
                                          }
                                        });
                                  },
                                ),
                              ],
                            ),
                            TextFormField(
                              controller: item['name'],
                              maxLength: 160,
                              decoration: const InputDecoration(
                                labelText: '품목 *',
                              ),
                              validator: _required,
                            ),
                            TextFormField(
                              controller: item['specification'],
                              maxLength: 300,
                              decoration: const InputDecoration(
                                labelText: '규격/사양',
                              ),
                            ),
                            Row(
                              spacing: 12,
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: item['quantity'],
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: '수량 *',
                                    ),
                                    validator: (v) =>
                                        RegExp(
                                              r'^\d+(\.\d{1,3})?$',
                                            ).hasMatch(v?.trim() ?? '') &&
                                            (double.tryParse(v!.trim()) ?? 0) >
                                                0
                                        ? null
                                        : '0보다 큰 수 (소수 셋째 자리까지)',
                                  ),
                                ),
                                Expanded(
                                  child: TextFormField(
                                    controller: item['unit_price'],
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                    ],
                                    decoration: const InputDecoration(
                                      labelText: '단가(원) *',
                                    ),
                                    validator: _required,
                                  ),
                                ),
                              ],
                            ),
                            TextFormField(
                              controller: item['note'],
                              maxLength: 200,
                              decoration: const InputDecoration(
                                labelText: '비고',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _items.length >= 20
                          ? null
                          : () => setState(() => _items.add(_controllers({}))),
                      icon: const Icon(Icons.add),
                      label: const Text('품목 추가'),
                    ),
                  ),
                ],
              ),
            ),
            FormActions(
              child: FilledButton(onPressed: _done, child: const Text('확인')),
            ),
          ],
        ),
      ),
    ),
  );
}
