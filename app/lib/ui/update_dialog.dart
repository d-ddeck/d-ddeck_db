import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/version.dart';
import '../services/update_service.dart';

bool _updateDialogOpen = false;

Future<void> checkClientUpdate(
  BuildContext context,
  String serverUrl, {
  bool silent = false,
}) async {
  if (!UpdateService.supported) {
    if (!silent && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Windows와 Android에서 업데이트할 수 있습니다.')),
      );
    }
    return;
  }
  if (_updateDialogOpen) return;
  _updateDialogOpen = true;
  final service = UpdateService();
  try {
    final update = await service.check(serverUrl);
    if (!context.mounted) return;
    if (update == null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('현재 받을 수 있는 새 업데이트가 없습니다.')),
        );
      }
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(service: service, update: update),
    );
  } catch (_) {
    if (!silent && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('업데이트를 확인하지 못했습니다. 서버 연결을 확인한 후 다시 시도해 주세요.'),
        ),
      );
    }
  } finally {
    _updateDialogOpen = false;
  }
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.service, required this.update});
  final UpdateService service;
  final ClientUpdate update;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  CancelToken? _cancel;
  File? _file;
  bool _busy = false;
  double _progress = 0;
  String? _error;
  String? _message;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      _cancel = CancelToken();
      _file ??= await widget.service.download(widget.update, _cancel!, (value) {
        if (mounted) setState(() => _progress = value);
      });
      if (!mounted) return;
      final opened = await widget.service.install(_file!, widget.update);
      if (mounted) {
        setState(
          () => _message = opened
              ? '설치 화면에서 업데이트를 완료해 주세요. 취소했다면 다시 설치할 수 있습니다.'
              : '설정에서 이 앱의 설치를 허용한 뒤 돌아와 “설치 계속”을 눌러 주세요.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _file = null;
          _error = '업데이트를 완료하지 못했습니다. 연결과 저장 공간을 확인한 후 다시 시도해 주세요.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('새 업데이트가 있습니다'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$appVersion → ${widget.update.version}+${widget.update.build}',
              ),
              const SizedBox(height: 12),
              Text(
                '다운로드 크기: ${(widget.update.size / (1024 * 1024)).toStringAsFixed(1)} MB',
              ),
              const SizedBox(height: 8),
              const Text('작성 중인 내용을 저장한 후 업데이트하세요. 설치 과정에서 앱이 종료될 수 있습니다.'),
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress),
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}% · 다운로드 및 파일 확인 중',
                ),
              ],
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(_message!),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancel?.cancel();
            Navigator.of(context).pop();
          },
          child: Text(_busy ? '다운로드 취소' : '나중에'),
        ),
        FilledButton(
          onPressed: _busy ? null : _run,
          child: Text(
            _file != null ? '설치 계속' : (_error != null ? '다시 시도' : '다운로드 및 설치'),
          ),
        ),
      ],
    ),
  );
}
