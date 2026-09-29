import 'dart:async';

import 'package:flutter/material.dart';
import '../../data/admin_repository.dart';
import '../../core/api_exception.dart';

/// Credentials are handled by the server and Google's browser login.
class DriveSetupDialog extends StatefulWidget {
  const DriveSetupDialog({super.key, required this.repository});
  final AdminRepository repository;

  @override
  State<DriveSetupDialog> createState() => _DriveSetupDialogState();
}

class _DriveSetupDialogState extends State<DriveSetupDialog> {
  Map<String, dynamic>? _data;
  final _answer = TextEditingController();
  final _folder = TextEditingController(text: 'D.DDECK 백업');
  String _parent = '';
  List<String> _folders = [];
  String? _choice;
  String? _error;
  bool _busy = false;
  bool _polling = false;
  bool _create = true;
  Timer? _timer;
  String get _id => _data!['id'] as String;
  String? get _stage => _data?['stage'] as String?;

  @override
  void initState() {
    super.initState();
    _start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _answer.dispose();
    _folder.dispose();
    super.dispose();
  }

  void _accept(Map<String, dynamic> data) {
    if (!mounted) return;
    final old = _stage;
    final oldName = (_data?['option'] as Map?)?['Name'];
    setState(() {
      _data = data;
      if (_stage == 'question' &&
          (old != 'question' || oldName != (data['option'] as Map?)?['Name'])) {
        final option = (data['option'] as Map?) ?? {};
        final value = option['Default']?.toString() ?? '';
        _answer.text = value;
        _choice = value;
      }
    });
    if (old != 'ready' && _stage == 'ready') _browse('');
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = e is ApiException ? e.message : '연결 상태를 확인하고 다시 시도하세요.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() => _run(() async {
    _accept(await widget.repository.startDriveSetup());
  });

  Future<void> _poll() async {
    if (_stage != 'working' || _busy || _polling) return;
    _polling = true;
    try {
      _accept(await widget.repository.driveSetup(_id));
    } catch (_) {
      if (mounted) {
        setState(() => _error = '서버 연결을 확인하세요. 인증 상태를 다시 확인하고 있습니다.');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _browse(String parent) async {
    try {
      final folders = await widget.repository.driveSetupFolders(_id, parent);
      if (mounted) {
        setState(() {
          _parent = parent;
          _folders = folders;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '폴더를 불러오지 못했습니다. 공유 드라이브 접근 권한을 확인하세요.');
      }
    }
  }

  Future<void> _cancel() => _run(() async {
    try {
      if (_data != null && _stage != 'saved') {
        await widget.repository.cancelDriveSetup(_id);
      }
    } finally {
      // Closing the dialog never applies a pending connection. Allow closing
      // even after expiry or a lost server connection.
      if (mounted) Navigator.pop(context, false);
    }
  });

  String _title(String name) => switch (name) {
    'config_shared_client_id' => 'Google 인증 방식',
    'client_id' => 'Google OAuth 클라이언트 ID',
    'client_secret' => 'Google OAuth 클라이언트 보안 비밀번호',
    'config_team_drive' ||
    'config_team_drive_id' ||
    'team_drive' => '공유 드라이브 선택',
    _ => 'Google 연결 설정',
  };

  @override
  Widget build(BuildContext context) {
    final option = (_data?['option'] as Map?) ?? {};
    final name = option['Name']?.toString() ?? '';
    final choices = ((option['Examples'] as List?) ?? []).cast<Map>();
    final onlyChoices = option['Exclusive'] == true && choices.isNotEmpty;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Google 계정 연결'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_stage == null || _stage == 'working') ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 16),
                  const Text(
                    '서버 PC의 브라우저에서 Google 로그인을 완료하세요. 인증 후 공유 드라이브를 선택할 수 있습니다.',
                  ),
                ],
                if (_stage == 'question') ...[
                  Text(
                    _title(name),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    name == 'config_shared_client_id'
                        ? '공용 Google 인증 설정은 2026년 중 종료될 수 있습니다. 회사 OAuth 앱을 등록하거나 공용 설정으로 연결을 시도할 수 있습니다.'
                        : option['Help']?.toString() ?? '',
                  ),
                  const SizedBox(height: 12),
                  if (onlyChoices)
                    DropdownButtonFormField<String>(
                      key: ValueKey(name),
                      initialValue:
                          choices.any((e) => e['Value'].toString() == _choice)
                          ? _choice
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '선택'),
                      items: choices.map((e) {
                        final value = e['Value'].toString();
                        final label = name == 'config_shared_client_id'
                            ? (value == 'true'
                                  ? '공용 설정으로 연결 시도'
                                  : '회사 OAuth 앱 등록')
                            : e['Help']?.toString() ?? value;
                        return DropdownMenuItem(
                          value: value,
                          child: Text(label, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _choice = v),
                    )
                  else
                    TextField(
                      controller: _answer,
                      obscureText:
                          option['IsPassword'] == true ||
                          name == 'client_secret',
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(labelText: _title(name)),
                    ),
                ],
                if (_stage == 'ready') ...[
                  const Text(
                    '백업 폴더 선택',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(_parent.isEmpty ? '공유 드라이브 최상위' : _parent),
                  if (_parent.isNotEmpty)
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _browse(
                              _parent.contains('/')
                                  ? _parent.substring(
                                      0,
                                      _parent.lastIndexOf('/'),
                                    )
                                  : '',
                            ),
                      icon: const Icon(Icons.arrow_upward),
                      label: const Text('상위 폴더'),
                    ),
                  for (final folder in _folders)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(folder),
                      onTap: _busy
                          ? null
                          : () {
                              final path = _parent.isEmpty
                                  ? folder
                                  : '$_parent/$folder';
                              setState(() {
                                _folder.text = path;
                                _create = false;
                              });
                              _browse(path);
                            },
                    ),
                  TextButton(
                    onPressed: _busy ? null : () => _browse(_parent),
                    child: const Text('폴더 새로고침'),
                  ),
                  TextField(
                    controller: _folder,
                    decoration: const InputDecoration(labelText: '백업 폴더 경로'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _create,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _create = v!),
                    title: const Text('폴더가 없으면 만들기'),
                  ),
                  const Text('저장하면 이후 백업에 적용됩니다. 업로드 검증 후 최근 30개를 유지합니다.'),
                ],
                if (_stage == 'error') const Text('Google 연결을 완료하지 못했습니다.'),
                if (_error != null || _data?['error'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error ?? _data!['error'].toString(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _cancel,
            child: const Text('취소'),
          ),
          if (_stage == 'question')
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      _accept(
                        await widget.repository.answerDriveSetup(
                          _id,
                          onlyChoices ? (_choice ?? '') : _answer.text.trim(),
                        ),
                      );
                    }),
              child: const Text('다음'),
            ),
          if (_stage == 'ready')
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await widget.repository.finishDriveSetup(
                        _id,
                        _folder.text.trim(),
                        _create,
                      );
                      if (context.mounted) Navigator.pop(context, true);
                    }),
              child: const Text('이 폴더에 백업'),
            ),
          if (_stage == 'error' || (_stage == null && !_busy))
            FilledButton(
              onPressed: _busy ? null : _start,
              child: const Text('다시 시도'),
            ),
        ],
      ),
    );
  }
}
