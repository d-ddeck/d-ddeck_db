import 'worklog_detail_page.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../data/file_repository.dart';
import '../../data/worklog_repository.dart';
import '../../models/common.dart';
import '../../models/worklog.dart';
import '../../state/auth_state.dart';
import '../common/attachment_section.dart';
import '../common/common.dart';
import '../format.dart';

/// Number only after IME composition has committed; keep edits and selection in place.
class WorkLogSummaryFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed || newValue.text.isEmpty) {
      return newValue;
    }
    var text = newValue.text;
    var base = newValue.selection.baseOffset;
    var extent = newValue.selection.extentOffset;
    void insert(int offset, String prefix) {
      text = text.substring(0, offset) + prefix + text.substring(offset);
      if (base >= offset) base += prefix.length;
      if (extent >= offset) extent += prefix.length;
    }

    if ((oldValue.text.isEmpty ||
            (!oldValue.composing.isCollapsed &&
                oldValue.composing.start == 0)) &&
        !RegExp(r'^\s*\d+\.\s').hasMatch(text)) {
      insert(0, '1. ');
    }
    final caret = extent;
    if (newValue.text.length > oldValue.text.length &&
        caret > 0 &&
        caret <= text.length &&
        text[caret - 1] == '\n' &&
        !RegExp(r'^\d+\.\s').hasMatch(text.substring(caret))) {
      final number = '\n'.allMatches(text.substring(0, caret)).length + 1;
      insert(caret, '$number. ');
    }
    return newValue.copyWith(
      text: text,
      selection: TextSelection(baseOffset: base, extentOffset: extent),
      composing: TextRange.empty,
    );
  }
}

class WorkLogFormPage extends StatefulWidget {
  const WorkLogFormPage({super.key, this.id});
  final String? id;
  @override
  State<WorkLogFormPage> createState() => _WorkLogFormPageState();
}

class _WorkLogFormPageState extends State<WorkLogFormPage> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{
    for (final name in ['summary', 'detail', 'overtime_note', 'plan', 'needs'])
      name: TextEditingController(),
  };
  WorkLogLookups? _lookups;
  WorkLog? _original;
  Map<String, dynamic> _baseline = {};
  String _date = Fmt.date(DateTime.now()), _start = '09:00', _end = '18:00';
  String _position = '', _visibility = 'PRIVATE';
  bool _overtime = false, _loading = true, _busy = false, _dirty = false;
  bool _allowPop = false, _leaving = false;
  String? _error;
  bool _draftFailed = false;
  DateTime? _savedAt, _restoredAt;
  Timer? _timer;
  Future<void>? _draftInFlight;
  int _revision = 0;
  bool get _creating => widget.id == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = context.read<WorkLogRepository>();
    try {
      final lookup = await repo.lookups();
      final log = _creating ? null : await repo.get(widget.id!);
      if (!mounted) return;
      if (log != null && !log.canEdit) {
        setState(() {
          _error = '수정 권한이 없습니다.';
          _loading = false;
        });
        return;
      }
      _lookups = lookup;
      _original = log;
      _fill(log?.toForm() ?? lookup.draft?.data ?? {});
      _baseline = _data;
      _savedAt = _creating ? lookup.draft?.savedAt : null;
      _restoredAt = _savedAt;
      setState(() => _loading = false);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '오류가 발생했습니다: $e';
          _loading = false;
        });
      }
    }
  }

  void _fill(Map<String, dynamic> data) {
    _date = asString(data['work_date'], Fmt.date(DateTime.now()));
    _start = asString(data['work_start'], _lookups!.defaultWorkStart);
    _end = asString(data['work_end'], _lookups!.defaultWorkEnd);
    // An administrator editing somebody else's log keeps that author's position.
    final ownLog =
        _original == null ||
        _original!.authorId == context.read<AuthState>().user?.id;
    _position = ownLog && _lookups!.fixedPosition.isNotEmpty
        ? _lookups!.fixedPosition
        : asString(data['position']);
    _visibility = data['visibility'] == 'TEAM' ? 'TEAM' : 'PRIVATE';
    _overtime = asBool(data['overtime']);
    for (final field in _fields.entries) {
      field.value.text = asString(data[field.key]);
    }
    if (!_overtime) _fields['overtime_note']!.clear();
  }

  Map<String, dynamic> get _data => {
    'work_date': _date,
    'work_start': _start,
    'work_end': _end,
    'position': _position,
    'visibility': _visibility,
    'overtime': _overtime,
    for (final field in _fields.entries) field.key: field.value.text,
    if (!_overtime) 'overtime_note': '',
  };

  void _changed() {
    _revision++;
    _dirty = true;
    if (mounted) setState(() {});
    if (!_creating || _busy) return;
    _timer?.cancel();
    _timer = Timer(
      Duration(seconds: _draftFailed ? 30 : (_lookups?.autosaveSeconds ?? 5)),
      _saveDraft,
    );
    setState(() {});
  }

  Future<void> _saveDraft() async {
    if (!_creating || _busy || !_dirty) return;
    if (_draftInFlight != null) {
      await _draftInFlight;
      if (mounted && _dirty && !_busy && !_draftFailed) await _saveDraft();
      return;
    }
    _timer?.cancel();
    final repo = context.read<WorkLogRepository>();
    final data = _data;
    final revision = _revision;
    final operation = () async {
      try {
        final draft = await repo.putDraft(data);
        if (!mounted) return;
        setState(() {
          _draftFailed = false;
          _savedAt = draft.savedAt;
          if (_revision == revision) _dirty = false;
        });
      } catch (_) {
        if (mounted) setState(() => _draftFailed = true);
      }
    }();
    _draftInFlight = operation;
    setState(() {});
    await operation;
    _draftInFlight = null;
    if (mounted) setState(() {});
  }

  Future<void> _leave() async {
    if (_busy || _leaving) return;
    _leaving = true;
    await _saveDraft();
    if (!mounted) return;
    if (_dirty &&
        !await ConfirmDialog.show(
          context,
          title: '저장하지 않고 나가기',
          message: '저장하지 못한 변경 사항이 있습니다. 그래도 나가시겠습니까?',
          confirmLabel: '나가기',
        )) {
      _leaving = false;
      return;
    }
    _leaving = false;
    if (!mounted) return;
    _timer?.cancel();
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _discard() async {
    setState(() => _busy = true);
    _timer?.cancel();
    final repo = context.read<WorkLogRepository>();
    await _draftInFlight;
    if (!mounted) return;
    final ok = await runGuarded(context, repo.deleteDraft);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _fill({});
        _savedAt = null;
        _restoredAt = null;
        _dirty = false;
        _revision++;
      }
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final repo = context.read<WorkLogRepository>();
    final data = _data;
    setState(() => _busy = true);
    _timer?.cancel();
    // Finish any PUT before POST, which deletes the draft on the server.
    await _draftInFlight;
    if (!mounted) return;
    try {
      final log = _creating
          ? await repo.create(data)
          : await repo.update(widget.id!, {
              for (final entry in data.entries)
                if (entry.value != _baseline[entry.key]) entry.key: entry.value,
            });
      if (!mounted) return;
      _dirty = false;
      _savedAt = null;
      AppSnack.saved(
        context,
        label: '${log.workDate} 근무일지',
        detail: () => WorkLogDetailPage(id: log.id),
      );
      setState(() {
        _busy = false;
        _allowPop = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(log.id);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      AppSnack.show(context, e.message, error: true);
      final id = asString(asMap(e.details)['id']);
      if (e.statusCode == 409 && e.code == 'WORKLOG_EXISTS' && id.isNotEmpty) {
        final savedId = await Navigator.of(context).push<String>(
          MaterialPageRoute<String>(builder: (_) => WorkLogFormPage(id: id)),
        );
        if (!mounted) return;
        setState(() {
          _busy = false;
          if (savedId != null) _allowPop = true;
        });
        if (savedId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop(savedId);
          });
        } else if (_dirty) {
          _changed();
        }
      } else {
        setState(() => _busy = false);
        if (_creating && _dirty) _changed();
      }
    } catch (e) {
      if (mounted) {
        AppSnack.show(context, '오류가 발생했습니다: $e', error: true);
        setState(() => _busy = false);
      }
    }
  }

  Widget _text(
    String name,
    String label, {
    bool required = false,
    int lines = 3,
  }) => TextFormField(
    controller: _fields[name],
    minLines: lines,
    maxLines: null,
    maxLength: name == 'overtime_note' ? 200 : null,
    decoration: InputDecoration(
      labelText: '$label${required ? ' *' : ''}',
      alignLabelWithHint: true,
    ),
    inputFormatters: name == 'summary' ? [WorkLogSummaryFormatter()] : null,
    validator: required
        ? (v) =>
              (v ?? '')
                  .replaceAll(RegExp(r'^\s*\d+\.\s*', multiLine: true), '')
                  .trim()
                  .isEmpty
              ? '$label을 입력해 주세요.'
              : null
        : null,
    onChanged: (_) => _changed(),
  );

  Future<void> _pickTime(bool start) async {
    final parts = (start ? _start : _end).split(':');
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: (int.tryParse(parts.first) ?? 9).clamp(0, 23),
        minute: (int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0).clamp(
          0,
          59,
        ),
      ),
    );
    if (time == null || !mounted) return;
    final value =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (start) {
        _start = value;
      } else {
        _end = value;
      }
    });
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final lookup = _lookups;
    final otherAuthor =
        _original != null &&
        _original!.authorId != context.read<AuthState>().user?.id;
    final fixedPosition =
        otherAuthor || (lookup?.fixedPosition.isNotEmpty ?? false);
    final positions = {
      ...?lookup?.positions,
      if (_position.isNotEmpty) _position,
    };
    return PopScope(
      canPop: !_busy && (_allowPop || !_dirty),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_creating ? '근무일지 등록' : '근무일지 수정')),
        body: _loading
            ? const LoadingState()
            : _error != null
            ? ErrorState(message: _error!, onRetry: _load)
            : Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: PageBody(
                        child: AbsorbPointer(
                          absorbing: _busy,
                          child: Form(
                            key: _form,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_restoredAt != null)
                                  Card(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondaryContainer,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            '${Fmt.time(_restoredAt)} 에 임시 저장한 내용을 불러왔습니다',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSecondaryContainer,
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: _discard,
                                            child: const Text('버리고 새로 쓰기'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                if (_restoredAt != null) const FormGap(),
                                FormSection(
                                  title: '기본 정보',
                                  children: [
                                    InputDecorator(
                                      decoration: const InputDecoration(
                                        labelText: '작성자',
                                      ),
                                      child: Text(
                                        _original?.authorName ??
                                            lookup!.authorName,
                                      ),
                                    ),
                                    if (fixedPosition)
                                      InputDecorator(
                                        decoration: const InputDecoration(
                                          labelText: '직급 *',
                                        ),
                                        child: Text(_position),
                                      )
                                    else
                                      DropdownButtonFormField<String>(
                                        key: ValueKey(_position),
                                        initialValue: _position.isEmpty
                                            ? null
                                            : _position,
                                        decoration: const InputDecoration(
                                          labelText: '직급 *',
                                        ),
                                        items: [
                                          for (final p in positions)
                                            DropdownMenuItem(
                                              value: p,
                                              child: Text(p),
                                            ),
                                        ],
                                        validator: (v) => v == null || v.isEmpty
                                            ? '직급을 선택해 주세요.'
                                            : null,
                                        onChanged: (v) {
                                          setState(() => _position = v ?? '');
                                          _changed();
                                        },
                                      ),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        final date = await pickDate(
                                          context,
                                          DateTime.tryParse(_date),
                                        );
                                        if (date != null && mounted) {
                                          setState(
                                            () => _date = Fmt.date(date),
                                          );
                                          _changed();
                                        }
                                      },
                                      icon: const Icon(Icons.calendar_today),
                                      label: Text('일자 *  $_date'),
                                    ),
                                    Wrap(
                                      spacing: 12,
                                      children: [
                                        OutlinedButton(
                                          onPressed: () => _pickTime(true),
                                          child: Text('시작 *  $_start'),
                                        ),
                                        OutlinedButton(
                                          onPressed: () => _pickTime(false),
                                          child: Text('종료 *  $_end'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const FormGap(),
                                FormSection(
                                  title: '금일 업무',
                                  children: [
                                    _text(
                                      'summary',
                                      '금일 업무 내용 요약',
                                      required: true,
                                    ),
                                    _text(
                                      'detail',
                                      '금일 근무 내용 상세',
                                      required: true,
                                      lines: 5,
                                    ),
                                    const Text('공개 범위'),
                                    RadioGroup<String>(
                                      groupValue: _visibility,
                                      onChanged: (v) {
                                        setState(() => _visibility = v!);
                                        _changed();
                                      },
                                      child: const Column(
                                        children: [
                                          RadioListTile<String>(
                                            title: Text('비공개 = 나와 관리자만'),
                                            value: 'PRIVATE',
                                          ),
                                          RadioListTile<String>(
                                            title: Text('팀 공개 = 로그인한 모두'),
                                            value: 'TEAM',
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Text('연장 근무'),
                                    RadioGroup<bool>(
                                      groupValue: _overtime,
                                      onChanged: (v) {
                                        setState(() {
                                          _overtime = v!;
                                          if (!v) {
                                            _fields['overtime_note']!.clear();
                                          }
                                        });
                                        _changed();
                                      },
                                      child: const Column(
                                        children: [
                                          RadioListTile<bool>(
                                            title: Text('X'),
                                            value: false,
                                          ),
                                          RadioListTile<bool>(
                                            title: Text('O'),
                                            value: true,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_overtime)
                                      _text('overtime_note', '연장 근무 내용'),
                                    _text('plan', '예정 업무'),
                                    _text('needs', '필요/요청사항'),
                                  ],
                                ),
                                const FormGap(),
                                if (_creating)
                                  const SectionCard(
                                    title: '첨부',
                                    child: Text('등록한 뒤 첨부할 수 있습니다'),
                                  )
                                else
                                  AttachmentSection(
                                    entityType: FileRepository.worklog,
                                    entityId: widget.id!,
                                    canEdit: _original!.canEdit,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FormActions(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_draftFailed)
                            const Text(
                              '임시 저장에 실패했습니다. 연결을 확인하거나 나중에 다시 저장해 주세요.',
                            ),
                          if (_creating)
                            Text(
                              _draftInFlight != null
                                  ? '임시 저장 중…'
                                  : _savedAt == null
                                  ? '입력을 멈추면 5초 뒤 임시 저장합니다'
                                  : '임시 저장됨 ${Fmt.time(_savedAt)}${_dirty ? ' · 저장할 변경 있음' : ''}',
                            ),
                          Row(
                            children: [
                              if (_creating) ...[
                                OutlinedButton(
                                  onPressed: _busy || _draftInFlight != null
                                      ? null
                                      : () {
                                          _dirty = true;
                                          _saveDraft();
                                        },
                                  child: const Text('임시 저장'),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: FilledButton(
                                  onPressed: _busy ? null : _save,
                                  child: Text(_busy ? '저장 중…' : '저장'),
                                ),
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
    );
  }
}
