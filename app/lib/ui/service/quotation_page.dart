
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../models/common.dart';
import '../../models/quotation.dart';
import '../async_view.dart';
import '../common/common.dart';
import '../common/download.dart';
import '../format.dart';

/// 견적서 작성 화면에 보여 줄 체크리스트. 못 읽으면(예전 서버 등) 체크리스트 없이 쓴다.
Future<List<QuoteChecklistEntry>> loadQuoteChecklist(ApiClient api) async {
  try {
    final res = await api.get('/service/quotations/checklist');
    return [
      for (final e in res as List? ?? const [])
        QuoteChecklistEntry.fromJson(asMap(e)),
    ];
  } catch (_) {
    return const [];
  }
}

/// Saved versions are immutable; editing always starts from the latest snapshot.
class QuotationPage extends StatefulWidget {
  const QuotationPage({super.key, required this.ticketId});
  final String ticketId;
  @override
  State<QuotationPage> createState() => _QuotationPageState();
}

class _QuotationPageState extends State<QuotationPage> {
  final _key = GlobalKey<AsyncViewState<List<Map<String, dynamic>>>>();
  bool _busy = false;
  String get _path => '/service/tickets/${widget.ticketId}/quotations';
  Future<void> _edit(List<Map<String, dynamic>> versions) async {
    setState(() => _busy = true);
    await runGuarded(context, () async {
      final api = context.read<ApiClient>();
      final data = asMap(
        await api.get(
          versions.isEmpty
              ? '$_path/defaults'
              : '$_path/${versions.first['id']}',
        ),
      );
      final checklist = await loadQuoteChecklist(api);
      if (!mounted) return;
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => QuotationEditPage(
            path: _path,
            initial: versions.isEmpty ? data : asMap(data['snapshot']),
            baseVersion: versions.isEmpty
                ? 0
                : asInt(versions.first['version']),
            checklist: checklist,
          ),
        ),
      );
      if (saved == true) _key.currentState?.reload();
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete(Map<String, dynamic> version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('견적서 삭제'),
        content: Text(
          'v${version['version']} 견적서를 삭제하시겠습니까?\n삭제하면 목록에서 사라지고 PDF를 열 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await runGuarded(context, () async {
      await context.read<ApiClient>().delete('$_path/${version['id']}');
      if (mounted) _key.currentState?.reload();
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pdf(Map<String, dynamic> version, bool save) async {
    setState(() => _busy = true);
    await runGuarded(context, () async {
      final bytes = await context.read<ApiClient>().getBytes(
        '$_path/${version['id']}/pdf',
      );
      final name = asString(version['filename']);
      if (!save) {
        await saveAndOpenDownload(bytes, name);
        return;
      }
      final path = await savePdfAs(bytes, name, dialogTitle: '견적 PDF 저장');
      if (path != null && mounted) AppSnack.show(context, savedMessage(path));
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('견적서 · 수정 이력')),
    body: PageBody(
      child: AsyncView<List<Map<String, dynamic>>>(
        key: _key,
        load: () async => (await context.read<ApiClient>().get(_path) as List)
            .map(asMap)
            .toList(),
        builder: (context, versions, reload) => ListView(
          children: [
            const Text('저장할 때마다 새로운 PDF 버전이 추가됩니다. 이전 파일과 작성 내용은 그대로 보관됩니다.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : () => _edit(versions),
              icon: const Icon(Icons.edit_document),
              label: Text(versions.isEmpty ? '견적서 작성' : '최신 견적 수정 · 새 버전 저장'),
            ),
            const SizedBox(height: 20),
            if (versions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('아직 저장된 견적서가 없습니다.'),
              ),
            for (final v in versions)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'v${asInt(v['version']).toString().padLeft(3, '0')} · ${Fmt.money(asInt(v['total']))}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${v['author_name']} · ${Fmt.dateTime(asDate(v['created_at']))}',
                      ),
                      const SizedBox(height: 8),
                      SelectableText(asString(v['filename'])),
                      if (asString(v['revision_note']).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('수정 메모: ${v['revision_note']}'),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _pdf(v, false),
                            icon: const Icon(Icons.picture_as_pdf),
                            label: const Text('PDF 열기'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _pdf(v, true),
                            icon: const Icon(Icons.save_alt),
                            label: const Text('파일로 저장'),
                          ),
                          if (v['can_delete'] == true)
                            OutlinedButton.icon(
                              onPressed: _busy ? null : () => _delete(v),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('삭제'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class QuotationEditPage extends StatefulWidget {
  const QuotationEditPage({
    super.key,
    required this.path,
    required this.initial,
    required this.baseVersion,
    this.checklist = const [],
  });

  /// 접수 저장 전 견적서. 서버에 보내지 않고 작성한 본문을 돌려준다.
  const QuotationEditPage.draft({
    super.key,
    required this.initial,
    this.checklist = const [],
  }) : path = null,
       baseVersion = 0;

  /// 체크하면 안내사항과 품목을 채워 주는 항목들.
  final List<QuoteChecklistEntry> checklist;

  /// null 이면 임시 작성: 저장하면 POST 본문을 Navigator 결과로 돌려준다.
  final String? path;
  final Map<String, dynamic> initial;
  final int baseVersion;
  @override
  State<QuotationEditPage> createState() => _QuotationEditPageState();
}

class _QuoteItem {
  _QuoteItem(Map<String, dynamic> data)
    : fields = {
        for (final key in [
          'name',
          'specification',
          'quantity',
          'unit_price',
          'note',
        ])
          key: TextEditingController(
            text: data[key]?.toString() ?? (key == 'quantity' ? '1' : ''),
          ),
      };
  final Map<String, TextEditingController> fields;
  Map<String, String> get json =>
      fields.map((k, v) => MapEntry(k, v.text.trim()));

  /// 새로 추가한 그대로의 빈 칸(수량 기본값 1 외에는 비어 있음).
  bool get isBlank => json.entries.every(
    (e) => e.key == 'quantity'
        ? e.value == '1' || e.value.isEmpty
        : e.value.isEmpty,
  );

  /// 체크리스트가 넣은 품목을 손대지 않은 채 그대로 두었는지.
  bool matches(Map<String, String> template) => QuoteChecklistEntry.itemKeys
      .every((k) => (template[k] ?? '').trim() == json[k]);
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
  }
}

class _QuotationEditPageState extends State<QuotationEditPage> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  late final List<_QuoteItem> _items;
  late final Set<String> _checks;
  bool _busy = false;
  bool _dirty = false;
  late DateTime _date, _until;
  @override
  void initState() {
    super.initState();
    final data = widget.initial;
    _date = DateTime.tryParse(asString(data['quote_date'])) ?? DateTime.now();
    _until =
        DateTime.tryParse(asString(data['valid_until'])) ??
        _date.add(const Duration(days: 30));
    _fields = {
      for (final side in ['supplier', 'recipient'])
        for (final key in ['company', 'contact', 'address', 'phone', 'email'])
          '$side.$key': TextEditingController(
            text: asString(asMap(data[side])[key]),
          ),
      for (final key in ['bank_account', 'notes', 'revision_note'])
        key: TextEditingController(
          text: key == 'revision_note' ? '' : asString(data[key]),
        ),
    };
    _items = (data['items'] as List? ?? [])
        .map((e) => _QuoteItem(asMap(e)))
        .toList();
    if (_items.isEmpty) _items.add(_QuoteItem({}));
    _checks = {
      for (final id in data['checks'] as List? ?? const []) asString(id),
    };
  }

  /// 체크하면 안내사항·품목을 채우고, 풀면 손대지 않은 것만 다시 뺀다.
  void _toggleCheck(QuoteChecklistEntry entry, bool on) {
    final notes = _fields['notes']!;
    final kept = <String>[];
    final removed = <_QuoteItem>[];
    setState(() {
      _dirty = true;
      if (on) {
        _checks.add(entry.id);
        notes.text = addNotesBlock(notes.text, entry.notes);
        // 처음 열었을 때의 빈 품목 칸은 채워 넣을 품목으로 대신한다.
        if (entry.items.isNotEmpty &&
            _items.length == 1 &&
            _items.first.isBlank) {
          removed.add(_items.removeAt(0));
        }
        for (final item in entry.items) {
          if (_items.length >= 100) break;
          _items.add(_QuoteItem(item));
        }
      } else {
        _checks.remove(entry.id);
        final next = removeNotesBlock(notes.text, entry.notes);
        if (next == null) {
          kept.add('안내사항');
        } else {
          notes.text = next;
        }
        for (final template in entry.items) {
          final index = _items.indexWhere((i) => i.matches(template));
          if (index < 0) {
            kept.add('품목 ${template['name']}');
          } else {
            removed.add(_items.removeAt(index));
          }
        }
        if (_items.isEmpty) _items.add(_QuoteItem({}));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final item in removed) {
        item.dispose();
      }
    });
    if (kept.isNotEmpty) {
      AppSnack.show(context, '직접 고친 ${kept.join(', ')}은(는) 그대로 두었습니다.');
    }
  }

  Widget _checklist() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('체크리스트', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '체크하면 안내사항과 품목이 자동으로 채워집니다.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in widget.checklist)
                FilterChip(
                  label: Text(e.label),
                  tooltip: [
                    if (e.notes.isNotEmpty) e.notes,
                    if (e.items.isNotEmpty) '품목 ${e.items.length}개 추가',
                  ].join('\n'),
                  selected: _checks.contains(e.id),
                  onSelected: (v) => _toggleCheck(e, v),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  Future<bool> _leave() async {
    if (_busy) return false;
    if (!_dirty) return true;
    return await ConfirmDialog.show(
      context,
      title: '작성 취소',
      message: '아직 저장하지 않은 견적 내용을 닫을까요?',
      confirmLabel: '닫기',
    );
  }

  Widget _input(
    String label,
    TextEditingController c, {
    bool required = false,
    int maxLength = 200,
    int lines = 1,
    String? number,
    bool phone = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16, top: 4),
    child: TextFormField(
      controller: c,
      decoration: InputDecoration(labelText: required ? '$label *' : label),
      maxLength: maxLength,
      minLines: lines,
      maxLines: lines,
      inputFormatters: phone ? const [PhoneNumberFormatter()] : null,
      keyboardType: phone
          ? TextInputType.phone
          : number != null
          ? const TextInputType.numberWithOptions(decimal: true)
          : (lines > 1 ? TextInputType.multiline : TextInputType.text),
      onChanged: (_) => setState(() => _dirty = true),
      validator: (v) {
        final value = v?.trim() ?? '';
        if (required && value.isEmpty) return '$label을 입력해 주세요.';
        if (number != null) {
          final pattern = number == 'quantity'
              ? RegExp(r'^\d+(\.\d{1,3})?$')
              : RegExp(r'^\d+$');
          final n = num.tryParse(value);
          if (!pattern.hasMatch(value) ||
              n == null ||
              !n.isFinite ||
              n < 0 ||
              (number == 'quantity' && (n <= 0 || n > 1000000)) ||
              (number == 'price' && n > 10000000000)) {
            return number == 'quantity'
                ? '0 초과, 최대 1,000,000 (소수 3자리)'
                : '0~10,000,000,000의 정수';
          }
        }
        return null;
      },
    ),
  );
  Widget _party(String side, String title) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          _input(
            '회사명',
            _fields['$side.company']!,
            required: true,
            maxLength: 120,
          ),
          _input(side == 'supplier' ? '대표자' : '담당자', _fields['$side.contact']!),
          _input('주소', _fields['$side.address']!, maxLength: 300, lines: 2),
          _input('연락처', _fields['$side.phone']!, phone: true),
          _input('E-mail', _fields['$side.email']!),
        ],
      ),
    ),
  );
  Widget _totals() {
    final subtotal = quotationSubtotal(_items.map((e) => e.json));
    if (subtotal == null) return const Text('수량과 단가를 입력하면 합계가 계산됩니다.');
    final vat = (subtotal + 5) ~/ 10;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('공급가액: ${Fmt.money(subtotal)}'),
            const SizedBox(height: 8),
            Text('부가세 (10%): ${Fmt.money(vat)}'),
            const SizedBox(height: 8),
            Text(
              '합계금액: ${Fmt.money(subtotal + vat)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      AppSnack.show(context, '필수 항목과 숫자 입력을 확인해 주세요.', error: true);
      return;
    }
    if (_until.isBefore(DateTime(_date.year, _date.month, _date.day))) {
      AppSnack.show(context, '유효기간은 견적일자 이후여야 합니다.', error: true);
      return;
    }
    String day(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final body = {
      'base_version': widget.baseVersion,
      'quote_date': day(_date),
      'valid_until': day(_until),
      for (final side in ['supplier', 'recipient'])
        side: {
          for (final key in ['company', 'contact', 'address', 'phone', 'email'])
            key: _fields['$side.$key']!.text.trim(),
        },
      for (final key in ['bank_account', 'notes', 'revision_note'])
        key: _fields[key]!.text.trim(),
      'items': _items.map((e) => e.json).toList(),
      'checks': _checks.toList(),
    };
    final path = widget.path;
    if (path == null) {
      _dirty = false;
      Navigator.pop(context, body);
      return;
    }
    setState(() => _busy = true);
    final saved = await runGuarded(
      context,
      () => context.read<ApiClient>().post(path, body: body),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved) {
      _dirty = false;
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !_busy,
    onPopInvokedWithResult: (didPop, result) async {
      if (!didPop && await _leave() && context.mounted) {
        setState(() => _dirty = false);
        if (context.mounted) Navigator.pop(context);
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          '견적서 v${(widget.baseVersion + 1).toString().padLeft(3, '0')} 작성',
        ),
      ),
      body: PageBody(
        child: Form(
          key: _form,
          child: AbsorbPointer(
            absorbing: _busy,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '회사 양식 기준 · 부가세 10% · 원 단위 반올림\n저장하면 서비스 건에 PDF와 작성 내용이 함께 보관됩니다.',
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.event),
                        label: Text('견적일자 ${Fmt.date(_date)}'),
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: _date,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (d != null) {
                            setState(() {
                              _date = d;
                              _dirty = true;
                            });
                          }
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.event_available),
                        label: Text('유효기간 ${Fmt.date(_until)}'),
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: _until,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (d != null) {
                            setState(() {
                              _until = d;
                              _dirty = true;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _party('supplier', '공급자 정보'),
                  const SizedBox(height: 16),
                  _party('recipient', '수신자 정보'),
                  const SizedBox(height: 16),
                  _input('입금계좌', _fields['bank_account']!),
                  if (widget.checklist.isNotEmpty) ...[
                    _checklist(),
                    const SizedBox(height: 16),
                  ],
                  for (var i = 0; i < _items.length; i++)
                    Card(
                      key: ObjectKey(_items[i]),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '품목 ${i + 1}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '품목 삭제',
                                  onPressed: _items.length == 1
                                      ? null
                                      : () {
                                          final item = _items[i];
                                          setState(() {
                                            _items.removeAt(i);
                                            _dirty = true;
                                          });
                                          WidgetsBinding.instance
                                              .addPostFrameCallback(
                                                (_) => item.dispose(),
                                              );
                                        },
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _input(
                              '품목',
                              _items[i].fields['name']!,
                              required: true,
                              maxLength: 160,
                            ),
                            _input(
                              '규격/사양',
                              _items[i].fields['specification']!,
                              maxLength: 300,
                              lines: 2,
                            ),
                            _input(
                              '수량',
                              _items[i].fields['quantity']!,
                              required: true,
                              number: 'quantity',
                            ),
                            _input(
                              '단가(원)',
                              _items[i].fields['unit_price']!,
                              required: true,
                              number: 'price',
                            ),
                            _input('비고', _items[i].fields['note']!),
                          ],
                        ),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: _items.length >= 100
                        ? null
                        : () => setState(() {
                            _items.add(_QuoteItem({}));
                            _dirty = true;
                          }),
                    icon: const Icon(Icons.add),
                    label: const Text('품목 추가'),
                  ),
                  const SizedBox(height: 24),
                  _totals(),
                  const SizedBox(height: 16),
                  _input('안내사항', _fields['notes']!, maxLength: 4000, lines: 4),
                  _input(
                    '수정 메모',
                    _fields['revision_note']!,
                    maxLength: 500,
                    lines: 2,
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: Text(_busy ? 'PDF 생성 및 저장 중…' : '새 버전 PDF 생성 · 저장'),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
