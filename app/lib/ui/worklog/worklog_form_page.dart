import 'worklog_detail_page.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

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
import 'task_photo.dart';

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
    for (final name in ['overtime_note', 'plan', 'needs'])
      name: TextEditingController(),
  };
  final List<_TaskEntry> _tasks = [];
  // 업무에서 뺀 저장된 사진. 저장에 성공하면 첨부에서도 지운다.
  final Set<String> _removedPhotos = {};
  WorkLogLookups? _lookups;
  WorkLog? _original;
  Map<String, dynamic> _baseline = {};
  String _date = Fmt.date(DateTime.now()), _start = '09:00', _end = '18:00';
  String _position = '';
  bool _loading = true, _busy = false, _dirty = false;
  bool _allowPop = false, _leaving = false;
  bool get _overtime => overtimeMinutes(_start, _end) > 0;
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
    for (final task in _tasks) {
      task.dispose();
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
    for (final field in _fields.entries) {
      field.value.text = asString(data[field.key]);
    }
    _tasks.forEach(_disposeLater);
    _tasks
      ..clear()
      ..addAll([
        for (final t in data['tasks'] as List? ?? [])
          _TaskEntry(WorkLogTask.fromJson(asMap(t))),
      ]);
    if (_tasks.isEmpty) _tasks.addAll(_legacyTasks(data));
    if (_tasks.isEmpty) _tasks.add(_TaskEntry());
  }

  /// 저장한 일지에 새 사진을 올려 업무에 연결하고, 뺀 사진은 첨부에서 지운다.
  /// 사진이 실패해도 일지는 이미 저장됐으므로 알리고 넘어간다.
  Future<WorkLog> _attachPhotos(WorkLog log) async {
    final files = context.read<FileRepository>();
    final repo = context.read<WorkLogRepository>();
    final failed = <String>[];
    var uploaded = false;
    for (final task in _tasks) {
      for (final photo in task.images.where((p) => p.attachmentId == null)) {
        try {
          final attachment = await files.upload(
            entityType: FileRepository.worklog,
            entityId: log.id,
            filePath: photo.localPath!,
            fileName: photo.name,
          );
          photo.attachmentId = attachment.id;
          uploaded = true;
        } catch (_) {
          failed.add(photo.name);
        }
      }
    }
    if (uploaded) {
      log = await repo.update(log.id, {
        'tasks': [for (final t in _tasks) t.value.toJson()],
      });
    }
    for (final id in _removedPhotos) {
      try {
        await files.delete(id);
      } catch (_) {
        // 이미 지워졌거나 권한이 없으면 첨부 목록에 남는다. 일지에는 영향 없음.
      }
    }
    _removedPhotos.clear();
    if (failed.isNotEmpty && mounted) {
      AppSnack.show(
        context,
        '일지는 저장했지만 사진 ${failed.length}장을 올리지 못했습니다: ${failed.join(', ')}',
        error: true,
      );
    }
    return log;
  }

  Future<void> _pickPhotos(_TaskEntry task) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );
    if (result == null || !mounted) return;
    setState(() {
      for (final file in result.files) {
        if (file.path == null || task.images.length >= 20) continue;
        task.images.add(_PhotoEntry(localPath: file.path, name: file.name));
      }
    });
    _changed();
  }

  Widget _photoTile(_TaskEntry task, _PhotoEntry photo) => SizedBox(
    width: 160,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            photo.attachmentId != null
                ? TaskPhotoThumb(attachmentId: photo.attachmentId!)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(photo.localPath!),
                      width: 160,
                      height: 120,
                      fit: BoxFit.cover,
                      cacheWidth: 320,
                      errorBuilder: (_, _, _) => const SizedBox(
                        width: 160,
                        height: 120,
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
            Positioned(
              top: 2,
              right: 2,
              child: IconButton.filledTonal(
                tooltip: '사진 빼기',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  setState(() {
                    task.images.remove(photo);
                    if (photo.attachmentId != null) {
                      _removedPhotos.add(photo.attachmentId!);
                    }
                  });
                  _disposeLaterPhoto(photo);
                  _changed();
                },
                icon: const Icon(Icons.close, size: 16),
              ),
            ),
          ],
        ),
        TextField(
          controller: photo.comment,
          maxLength: 500,
          maxLines: 2,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '사진 코멘트',
            isDense: true,
            counterText: '',
          ),
          onChanged: (_) => _changed(),
        ),
      ],
    ),
  );

  void _disposeLaterPhoto(_PhotoEntry photo) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => photo.dispose());

  /// 지운 입력칸이 화면에서 빠진 뒤에 입력기를 정리한다.
  void _disposeLater(_TaskEntry task) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => task.dispose());

  /// 업무 목록 이전에 쓴 일지: 요약 줄마다 업무 하나, 예전 상세는 첫 업무에.
  List<_TaskEntry> _legacyTasks(Map<String, dynamic> data) {
    final titles = asString(data['summary'])
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^\s*\d+\.\s*'), '').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return [
      for (var i = 0; i < titles.length; i++)
        _TaskEntry(
          WorkLogTask(
            title: titles[i],
            detail: i == 0 ? asString(data['detail']) : '',
          ),
        ),
    ];
  }

  Map<String, dynamic> get _data => {
    'work_date': _date,
    'work_start': _start,
    'work_end': _end,
    'position': _position,
    for (final field in _fields.entries) field.key: field.value.text,
    'tasks': [for (final t in _tasks) t.value.toJson()],
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
      var log = _creating
          ? await repo.create(data)
          : await repo.update(widget.id!, {
              for (final entry in data.entries)
                if (entry.value != _baseline[entry.key]) entry.key: entry.value,
            });
      if (!mounted) return;
      log = await _attachPhotos(log);
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

  Widget _taskCard(int index) {
    final task = _tasks[index];
    String? required(String? v, String label) => (v ?? '').trim().isEmpty
        ? '$label${_objectParticle(label)} 입력해 주세요.'
        : null;
    void update(VoidCallback change) {
      setState(change);
      _changed();
    }

    return Card(
      key: task.key,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '업무 ${index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (_tasks.length > 1)
                  IconButton(
                    tooltip: '이 업무 삭제',
                    onPressed: () => update(() {
                      _disposeLater(_tasks.removeAt(index));
                    }),
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'AM', label: Text('오전')),
                    ButtonSegment(value: 'PM', label: Text('오후')),
                  ],
                  selected: {task.period},
                  onSelectionChanged: (v) =>
                      update(() => task.period = v.first),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'OFFICE',
                      label: Text('사무'),
                      icon: Icon(Icons.apartment_outlined),
                    ),
                    ButtonSegment(
                      value: 'TRIP',
                      label: Text('출장'),
                      icon: Icon(Icons.directions_car_outlined),
                    ),
                  ],
                  selected: {task.kind},
                  onSelectionChanged: (v) => update(() => task.kind = v.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (task.kind == 'TRIP') ...[
              TextFormField(
                controller: task.location,
                maxLength: 200,
                decoration: const InputDecoration(labelText: '출장지 *'),
                validator: (v) => required(v, '출장지'),
                onChanged: (_) => _changed(),
              ),
            ],
            TextFormField(
              controller: task.title,
              maxLength: 200,
              decoration: const InputDecoration(labelText: '업무 제목 *'),
              validator: (v) => required(v, '업무 제목'),
              onChanged: (_) => _changed(),
            ),
            TextFormField(
              controller: task.detail,
              minLines: 3,
              maxLines: null,
              maxLength: 4000,
              decoration: const InputDecoration(
                labelText: '업무 상세 내용',
                alignLabelWithHint: true,
              ),
              onChanged: (_) => _changed(),
            ),
            Row(
              children: [
                Text(
                  '사진 ${task.images.length}장',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: task.images.length >= 20
                      ? null
                      : () => _pickPhotos(task),
                  icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                  label: const Text('사진 추가'),
                ),
                const SizedBox(width: 8),
              ],
            ),
            if (task.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final photo in task.images) _photoTile(task, photo),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 받침이 있으면 '을', 없으면 '를' (예: 요약을, 사유를).
  static String _objectParticle(String word) {
    final code = word.isEmpty ? 0 : word.codeUnitAt(word.length - 1);
    if (code < 0xAC00 || code > 0xD7A3) return '을';
    return (code - 0xAC00) % 28 == 0 ? '를' : '을';
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
              ? '$label${_objectParticle(label)} 입력해 주세요.'
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
                                        spacing: 8,
                                        runSpacing: 12,
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
                                      runSpacing: 12,
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
                                    for (var i = 0; i < _tasks.length; i++)
                                      _taskCard(i),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: OutlinedButton.icon(
                                        onPressed: _tasks.length >= 30
                                            ? null
                                            : () {
                                                setState(
                                                  () => _tasks.add(
                                                    _TaskEntry(
                                                      WorkLogTask(
                                                        period:
                                                            _tasks.last.period,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                                _changed();
                                              },
                                        icon: const Icon(Icons.add),
                                        label: const Text('업무 추가'),
                                      ),
                                    ),
                                    if (_overtime) ...[
                                      Text(
                                        '연장 근무 ${overtimeLabel(overtimeMinutes(_start, _end))} · 18:00 이후 근무가 자동으로 연장 처리됩니다',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      _text(
                                        'overtime_note',
                                        '연장 근무 사유',
                                        required: true,
                                      ),
                                    ],
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

/// 입력 중인 업무 하나. 칸마다 입력기를 따로 둔다.
class _TaskEntry {
  _TaskEntry([WorkLogTask task = const WorkLogTask()])
    : period = task.period,
      kind = task.kind,
      location = TextEditingController(text: task.location),
      title = TextEditingController(text: task.title),
      detail = TextEditingController(text: task.detail) {
    images.addAll([
      for (final i in task.images)
        _PhotoEntry(attachmentId: i.attachmentId, comment: i.comment),
    ]);
  }

  String period, kind;
  final TextEditingController location, title, detail;
  late final List<_PhotoEntry> images = [];
  final key = UniqueKey();

  /// 아직 올리지 않은 사진은 빼고 보낸다(저장 뒤 올려서 다시 연결한다).
  WorkLogTask get value => WorkLogTask(
    period: period,
    kind: kind,
    location: location.text.trim(),
    title: title.text.trim(),
    detail: detail.text.trim(),
    images: [
      for (final p in images)
        if (p.attachmentId != null)
          WorkLogTaskImage(
            attachmentId: p.attachmentId!,
            comment: p.comment.text.trim(),
          ),
    ],
  );

  void dispose() {
    location.dispose();
    title.dispose();
    detail.dispose();
    for (final p in images) {
      p.dispose();
    }
  }
}

/// 업무 사진 하나: 저장된 첨부이거나, 저장할 때 올릴 기기 파일.
class _PhotoEntry {
  _PhotoEntry({
    this.attachmentId,
    this.localPath,
    this.name = 'photo.jpg',
    String comment = '',
  }) : comment = TextEditingController(text: comment);

  String? attachmentId;
  final String? localPath;
  final String name;
  final TextEditingController comment;

  void dispose() => comment.dispose();
}
