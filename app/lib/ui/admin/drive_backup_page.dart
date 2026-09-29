import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../common/common.dart';
import 'drive_setup_dialog.dart';
import 'drive_restore_page.dart';

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

  Future<void> _configureSharedDrive() async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          DriveSetupDialog(repository: context.read<AdminRepository>()),
    );
    await _load();
  }

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
        title: const Text('Google 공유 드라이브 백업'),
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
                    if (data['setup_available'] == true && connected)
                      OutlinedButton.icon(
                        onPressed: canAct
                            ? () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const DriveRestorePage(),
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.restore),
                        label: const Text('백업 다운로드 · 서버 복구'),
                      ),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connected
                                  ? (data['connection_type'] == 'rclone'
                                        ? 'Google 계정 연결됨'
                                        : '연결 계정: ${data['account']}')
                                  : '연결된 공유 드라이브가 없습니다',
                            ),
                            if (data['folder_name'] != null)
                              Text('백업 폴더: ${data['folder_name']}'),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed:
                                      canAct && data['setup_available'] == true
                                      ? _configureSharedDrive
                                      : null,
                                  icon: const Icon(
                                    Icons.account_circle_outlined,
                                  ),
                                  label: Text(
                                    connected ? '연동 계정 변경' : 'Google 계정으로 연결',
                                  ),
                                ),
                                if (connected)
                                  TextButton(
                                    onPressed: canAct ? _disconnect : null,
                                    child: const Text('연결 해제'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              data['setup_available'] == true
                                  ? '브라우저에서 Google 로그인 후 공유 드라이브와 백업 폴더를 선택하세요.'
                                  : 'Google 계정 연결·변경은 서버 PC 앱에서 진행하세요.',
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
                              'DB와 첨부파일을 ZIP으로 저장하고 업로드 결과를 검증합니다. 저장 위치: 설정한 공유 드라이브 백업 폴더. rclone 연결은 업로드 검증 후 최근 백업 ZIP 30개를 유지하고 오래된 파일부터 휴지통으로 이동합니다. 이전 서버의 백업 폴더와 일반 파일은 유지됩니다. 서버 환경설정(.env)과 Google 인증정보는 포함하지 않습니다.',
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
