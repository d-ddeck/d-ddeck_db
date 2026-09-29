import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../common/common.dart';

class DriveRestorePage extends StatefulWidget {
  const DriveRestorePage({super.key});
  @override
  State<DriveRestorePage> createState() => _DriveRestorePageState();
}

class _DriveRestorePageState extends State<DriveRestorePage> {
  List<Map<String, dynamic>> _files = [];
  bool _loading = true;
  bool _busy = false;
  bool _restorable = false;
  String? _error;
  String? _progress;
  String? _safety;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AdminRepository>().driveBackupFiles();
      if (mounted) {
        setState(() {
          _files = (data['files'] as List)
              .map((v) => Map<String, dynamic>.from(v as Map))
              .toList();
          _restorable = data['restore_supported'] == true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '백업 목록을 불러오지 못했습니다.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(String name, bool restore) async {
    final repo = context.read<AdminRepository>();
    String? destination;
    if (restore) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('이 백업으로 서버를 복구할까요?'),
          content: SingleChildScrollView(
            child: Text(
              '$name\n\n현재 DB와 첨부파일을 선택한 백업으로 교체합니다. 백업 이후 변경된 내용은 복구 결과에 포함되지 않습니다.\n\n현재 자료는 Google 드라이브에 안전 백업으로 보관하며, 복구 중 접속을 잠시 차단합니다. 완료 후 모든 사용자가 다시 로그인해야 합니다.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('현재 서버 복구'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    } else {
      destination = await FilePicker.platform.saveFile(
        dialogTitle: '백업 ZIP 저장',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (destination == null || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _safety = null;
      _progress = 'Google 백업 다운로드 중…';
    });
    try {
      final ticket = await repo.startBackupRestore(name, restore);
      while (mounted) {
        final data = await repo.backupRestoreStatus(ticket);
        final stage = data['stage'];
        setState(() {
          _safety = data['safety_backup'] as String?;
          _progress = switch (stage) {
            'validating' => '백업 파일과 DB 검증 중…',
            'safety_backup' => '현재 자료 Google 안전 백업 중…',
            'restoring' => '서버 복구 중…',
            'restored' => '복구 완료. 다시 로그인해 주세요.',
            'downloaded' => '선택한 위치에 파일 저장 중…',
            _ => 'Google 백업 다운로드 중…',
          };
        });
        if (stage == 'error') {
          throw ApiException(
            code: 'RESTORE_ERROR',
            message:
                '${data['error']}${data['maintenance'] == true ? '\n서버가 보호를 위해 점검 상태를 유지하고 있습니다. 안전 백업으로 복구를 완료해야 합니다.' : ''}',
          );
        }
        if (stage == 'restored') break;
        if (stage == 'downloaded') {
          await repo.downloadBackup(ticket, destination!);
          if (mounted) setState(() => _progress = '다운로드 완료: $destination');
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = e is ApiException
              ? e.message
              : '작업 상태를 확인하지 못했습니다. 서버 작업은 계속될 수 있으므로 완료 여부를 확인하세요.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('백업 다운로드 · 서버 복구'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
          ),
        ],
      ),
      body: PageBody(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  const Text('연결한 Google 공유 드라이브의 백업입니다. 복구는 서버 PC에서 진행합니다.'),
                  if (!_restorable)
                    const Text(
                      '현재 DB 형식은 다운로드만 지원합니다. 자동 복구는 SQLite 서버에서 사용할 수 있습니다.',
                    ),
                  if (_busy) const LinearProgressIndicator(),
                  if (_progress != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(_progress!),
                    ),
                  if (_safety != null)
                    SelectableText('복구 전 Google 안전 백업: $_safety'),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_files.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('백업 파일이 없습니다.'),
                    ),
                  for (final file in _files)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(file['name'] as String),
                            Text(
                              '${((file['size'] as num) / 1024 / 1024).toStringAsFixed(1)} MB',
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () =>
                                            _run(file['name'] as String, false),
                                  icon: const Icon(Icons.download),
                                  label: const Text('다운로드'),
                                ),
                                TextButton.icon(
                                  onPressed: _busy || !_restorable
                                      ? null
                                      : () =>
                                            _run(file['name'] as String, true),
                                  icon: const Icon(Icons.restore),
                                  label: const Text('서버 복구'),
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
