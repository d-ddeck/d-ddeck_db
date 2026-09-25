import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../data/worklog_repository.dart';
import '../../models/worklog.dart';
import '../../models/common.dart';
import '../../state/auth_state.dart';
import '../common/common.dart';
import '../theme.dart';
import '../common/download.dart';
import 'worklog_detail_page.dart';
import 'worklog_form_page.dart';

class WorkLogPage extends StatefulWidget {
  const WorkLogPage({super.key});
  @override
  State<WorkLogPage> createState() => _WorkLogPageState();
}

class _WorkLogPageState extends State<WorkLogPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  WorkLogLookups? _lookups;
  List<WorkLog> _rows = [];
  String _scope = 'mine';
  String? _lookupScope;
  int? _year = DateTime.now().year, _month;
  String? _author;
  bool? _overtime;
  int _page = 0, _request = 0;
  bool _loading = false, _more = false, _exporting = false;
  String? _error;

  Map<String, dynamic> get _filters => {
    'scope': _scope, 'year': _year, 'month': _month,
    'author_id': _author, 'overtime': _overtime, 'q': _search.text.trim(),
  };

  @override
  void initState() {
    super.initState();
    _load(refreshLookups: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false, bool refreshLookups = false}) async {
    final request = ++_request;
    final loadLookups = refreshLookups || _lookups == null || _lookupScope != _scope;
    final scope = _scope;
    final filters = _filters;
    final page = more ? _page + 1 : 1;
    final repo = context.read<WorkLogRepository>();
    setState(() {
      _loading = true; _error = null;
      if (!more) { _rows = []; _page = 0; _more = false; }
    });
    try {
      final results = await Future.wait<Object>([
        repo.list(filters: filters, page: page),
        if (loadLookups) repo.lookups(scope: scope),
      ]);
      if (!mounted || request != _request) return;
      // The two requests share one generation so stale filters cannot overwrite the view.
      final result = results.first as PagedList<WorkLog>;
      setState(() {
        _rows = more ? [..._rows, ...result.items] : result.items;
        _page = page;
        _more = result.hasMore;
        if (loadLookups) { _lookups = results[1] as WorkLogLookups; _lookupScope = scope; }
      });
    } on ApiException catch (e) {
      if (mounted && request == _request) setState(() => _error = e.message);
    } catch (e) {
      if (mounted && request == _request) setState(() => _error = '오류가 발생했습니다: $e');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _open({String? id}) async {
    _debounce?.cancel();
    var detailId = id;
    detailId ??= await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const WorkLogFormPage()));
    if (!mounted) return;
    if (detailId != null) {
      final selectedId = detailId;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => WorkLogDetailPage(id: selectedId)));
    }
    if (mounted) await _load(refreshLookups: true);
  }

  Future<void> _export() async {
    final repo = context.read<WorkLogRepository>();
    final filters = _filters;
    setState(() => _exporting = true);
    await runGuarded(context, () async {
      final bytes = await repo.exportXlsx(filters);
      await saveAndOpenDownload(bytes, '근무일지.xlsx');
    });
    if (mounted) setState(() => _exporting = false);
  }

  Widget _filter<T>(String label, T? value, List<DropdownMenuItem<T>> items,
      ValueChanged<T?> changed) => SizedBox(width: 160, child: DropdownButtonFormField<T>(
    initialValue: value, key: ValueKey('$label:$value:$_scope'), isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [DropdownMenuItem<T>(value: null, child: const Text('전체')), ...items],
    onChanged: (v) { setState(() => changed(v)); _load(); },
  ));

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<AuthState>().isAdmin;
    final years = {...?_lookups?.years, if (_year != null) _year!}.toList()..sort((a, b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, title: TextButton.icon(onPressed: () => _open(), icon: const Icon(Icons.add),
          label: Text(_lookups?.draft == null ? '오늘 근무일지 쓰기' : '임시 저장 이어서 쓰기',
            maxLines: 1, overflow: TextOverflow.ellipsis)), actions: [
        IconButton(tooltip: '엑셀', onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.download_outlined)),
      ]),
      body: SingleChildScrollView(child: PageBody(child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<String>(segments: [
          const ButtonSegment(value: 'mine', label: Text('내 일지')),
          ButtonSegment(value: admin ? 'all' : 'team', label: Text(admin ? '전체 보기' : '팀 공개 일지')),
        ], selected: {_scope}, onSelectionChanged: (values) {
          setState(() { _scope = values.first; _author = null; _rows = []; });
          _load(refreshLookups: true);
        }),
        const FormGap(),
        FilterBar(appliedFilters: [
          if (_year != null) '$_year년', if (_month != null) '$_month월',
          if (_author != null) '작성자 선택', if (_overtime != null) '연장 ${_overtime! ? '있음' : '없음'}',
          if (_search.text.trim().isNotEmpty) _search.text.trim(),
        ], onReset: () {
          _debounce?.cancel();
          setState(() { _year = null; _month = null; _author = null; _overtime = null; _search.clear(); });
          _load();
        }, children: [
          _filter<int>('연도', _year, [for (final y in years) DropdownMenuItem(value: y, child: Text('$y년'))], (v) => _year = v),
          _filter<int>('월', _month, [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text('$m월'))], (v) => _month = v),
          _filter<String>('작성자', _author, [
            for (final a in _lookups?.authors ?? []) DropdownMenuItem(value: a.id, child: Text(a.display)),
            if (_author != null && !(_lookups?.authors.any((a) => a.id == _author) ?? false))
              DropdownMenuItem(value: _author, child: const Text('선택한 작성자')),
          ], (v) => _author = v),
          _filter<bool>('연장 근무', _overtime, const [DropdownMenuItem(value: true, child: Text('있음')), DropdownMenuItem(value: false, child: Text('없음'))], (v) => _overtime = v),
          SizedBox(width: 240, child: TextField(controller: _search,
            decoration: const InputDecoration(labelText: '검색어', prefixIcon: Icon(Icons.search)),
            onChanged: (_) { _debounce?.cancel(); _debounce = Timer(const Duration(milliseconds: 400), () => _load()); })),
        ]),
        const FormGap(),
        if (_lookups?.draft != null) Card(color: Colors.amber.shade100,
          child: ListTile(textColor: Colors.black87, iconColor: Colors.black87,
            leading: const Icon(Icons.edit_note), title: const Text('임시 저장'),
            subtitle: const Text('누르면 이어서 작성합니다'), onTap: () => _open())),
        if (_lookups?.draft != null) const FormGap(),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) ErrorState(message: _error!, onRetry: () => _load(refreshLookups: true))
        else ResponsiveTable<WorkLog>(rows: _rows, onTap: (row) => _open(id: row.id), columns: [
          TableColumn(label: '일자', cell: (w) => Text(w.workDate)),
          TableColumn(label: '작성자(직급)', cell: (w) => Text('${w.authorName} ${w.position}')),
          TableColumn(label: '근무시간', cell: (w) => Text('${w.workStart}~${w.workEnd}')),
          TableColumn(label: '요약', flex: 3, cell: (w) => SizedBox(width: 240,
            child: Text(w.summary.split('\n').take(2).join('\n'), maxLines: 2, overflow: TextOverflow.ellipsis))),
          TableColumn(label: '표시', cell: (w) => Wrap(spacing: 4, children: [
            if (w.overtime) const Chip(label: Text('연장')),
            if (w.visibility == 'TEAM') const Chip(label: Text('팀 공개')),
          ])),
          TableColumn(label: '첨부', cell: (w) => Text('${w.attachmentCount}')),
        ]),
        if (_more && _error == null) const SizedBox(height: AppSpace.lg),
        if (_more && _error == null) TextButton(onPressed: _loading ? null : () => _load(more: true), child: const Text('더 보기')),
      ]))),
    );
  }
}
