import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/admin_repository.dart';
import '../common/common.dart';

class DriveBackupPage extends StatefulWidget {
  const DriveBackupPage({super.key});

  @override
  State<DriveBackupPage> createState() => _DriveBackupPageState();
}

class _DriveBackupPageState extends State<DriveBackupPage> {
  Map<String, dynamic>? _data;
  bool _busy = false;
  bool _loading = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || !mounted) return;
    _loading = true;
    try {
      final data = await context.read<AdminRepository>().driveBackup();
      if (mounted) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '백업 상태를 불러오지 못했습니다. 새로고침해 주세요.');
    } finally {
      _loading = false;
    }
  }

  Future<void> _act(Future<void> Function(AdminRepository) action) async {
    setState(() => _busy = true);
    final repo = context.read<AdminRepository>();
    await runGuarded(context, () => action(repo));
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _configure() async {
    final id = TextEditingController(
      text: _data?['client_id'] as String? ?? '',
    );
    final secret = TextEditingController();
    final redirect = TextEditingController(
      text: _data?['redirect_uri'] as String? ?? '',
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Google OAuth 앱 설정'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Google Cloud에서 Drive API를 사용 설정하고 웹 애플리케이션 OAuth 클라이언트를 생성하세요. 승인된 리디렉션 URI에 아래 콜백 주소를 동일하게 등록하세요.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: id,
                  decoration: const InputDecoration(labelText: '클라이언트 ID'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secret,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '클라이언트 보안 비밀번호',
                    helperText: '설정 후 빈칸으로 저장하면 기존 값 유지',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: redirect,
                  decoration: const InputDecoration(
                    labelText: '콜백 주소',
                    hintText: 'https://서버주소/api/v1/admin/drive-backup/callback',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    final values = {
      'client_id': id.text.trim(),
      'client_secret': secret.text.trim(),
      'redirect_uri': redirect.text.trim(),
    };
    // Dialog route owns the text fields until its closing animation completes.
    Future<void>.delayed(const Duration(seconds: 1), () {
      id.dispose();
      secret.dispose();
      redirect.dispose();
    });
    if (accepted == true && mounted) {
      await _act((r) async {
        await r.configureDriveBackup(values);
      });
    }
  }

  Future<void> _connect() => _act((repo) async {
    final url = await repo.connectDriveBackup();
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (mounted) {
      AppSnack.show(
        context,
        opened
            ? '브라우저에서 Google 계정을 선택하세요. 완료 후 이 화면에 반영됩니다.'
            : '브라우저를 열지 못했습니다. 기본 브라우저 설정을 확인하세요.',
        error: !opened,
      );
    }
  });

  Future<void> _disconnect() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('계정 연결 해제'),
        content: const Text('자동 백업이 중지됩니다. 드라이브의 기존 백업 파일은 유지됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('연결 해제'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _act((r) async {
        await r.disconnectDriveBackup();
      });
    }
  }

  String _date(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    return date == null ? '없음' : date.toString().split('.').first;
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final connected = data?['connected'] == true;
    final running = data?['running'] == true;
    final requested = data?['requested'] == true;
    final enabled = data?['enabled'] == true;
    final hour = (data?['hour'] as num?)?.toInt() ?? 3;
    final canAct = !_busy && !running;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Drive 자동 백업'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: PageBody(
        child: data == null && _error == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!),
                    ),
                  if (data != null) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connected
                                  ? '연결 계정: ${data['account']}'
                                  : '연결된 Google 계정이 없습니다',
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed:
                                      canAct && data['configured'] == true
                                      ? _connect
                                      : null,
                                  icon: const Icon(
                                    Icons.account_circle_outlined,
                                  ),
                                  label: Text(
                                    connected ? '연동 계정 변경' : 'Google 계정 연결',
                                  ),
                                ),
                                if (connected)
                                  TextButton(
                                    onPressed: canAct ? _disconnect : null,
                                    child: const Text('연결 해제'),
                                  ),
                                if (!connected)
                                  TextButton(
                                    onPressed: canAct ? _configure : null,
                                    child: const Text('OAuth 앱 설정'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '계정 변경은 새 계정 연결에 성공한 뒤 적용됩니다. 기존 백업은 이전 계정에 보관됩니다.',
                            ),
                          ],
                        ),
                      ),
                    ),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('매일 자동 백업'),
                              subtitle: const Text('서버가 켜져 있으면 앱을 종료해도 실행됩니다.'),
                              value: enabled,
                              onChanged:
                                  canAct &&
                                      connected &&
                                      data['scheduler_enabled'] == true
                                  ? (v) => _act((r) async {
                                      await r.scheduleDriveBackup(v, hour);
                                    })
                                  : null,
                            ),
                            if (data['scheduler_enabled'] != true)
                              const Text('서버 백업 실행기가 비활성화되어 있습니다.'),
                            Row(
                              children: [
                                const Text('백업 시간 (한국)  '),
                                DropdownButton<int>(
                                  value: hour,
                                  items: List.generate(
                                    24,
                                    (h) => DropdownMenuItem(
                                      value: h,
                                      child: Text(
                                        '${h.toString().padLeft(2, '0')}:00',
                                      ),
                                    ),
                                  ),
                                  onChanged: canAct
                                      ? (v) => _act((r) async {
                                          await r.scheduleDriveBackup(
                                            enabled,
                                            v!,
                                          );
                                        })
                                      : null,
                                ),
                              ],
                            ),
                            Text('다음 실행: ${_date(data['next_run_at'])}'),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed:
                                  canAct &&
                                      connected &&
                                      !requested &&
                                      data['scheduler_enabled'] == true
                                  ? () => _act((r) async {
                                      await r.runDriveBackup();
                                    })
                                  : null,
                              icon: const Icon(Icons.backup_outlined),
                              label: Text(
                                running
                                    ? '백업 중…'
                                    : requested
                                    ? '백업 대기 중…'
                                    : '지금 백업',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('마지막 성공: ${_date(data['last_success_at'])}'),
                            if (data['last_account'] != null)
                              Text('마지막 백업 계정: ${data['last_account']}'),
                            if (data['last_error'] != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  data['last_error'].toString(),
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 8),
                            const Text(
                              'DB와 첨부파일을 ZIP으로 저장하고 업로드 결과를 검증합니다. 저장 위치: 내 드라이브 → D.DDECK 자동 백업. 드라이브 백업은 자동 삭제하지 않습니다. 서버 환경설정(.env)과 Google 인증정보는 포함하지 않습니다.',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
