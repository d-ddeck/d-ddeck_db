import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/config.dart';
import '../../services/connection_profile.dart';
import '../../state/auth_state.dart';

class ConnectionSettingsPage extends StatefulWidget {
  const ConnectionSettingsPage({super.key});
  @override
  State<ConnectionSettingsPage> createState() => _ConnectionSettingsPageState();
}

class _ConnectionSettingsPageState extends State<ConnectionSettingsPage> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthState>();
    if (auth.isAdmin) _url.text = auth.serverUrl;
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _apply({required bool fromFile}) async {
    final auth = context.read<AuthState>();
    if (!fromFile && !auth.isAdmin) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      String url;
      if (fromFile) {
        final files = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json'],
          withData: true,
        );
        if (files == null) return;
        final file = files.files.single;
        if (file.size > 16384 || file.bytes == null) {
          throw const FormatException();
        }
        url = await ConnectionProfile.verify(
          utf8.decode(file.bytes!),
          await rootBundle.loadString('assets/connection_public_key.txt'),
        );
      } else {
        url = AppConfig.secureServerUrl(_url.text);
      }
      // Revoke the old server session before changing the destination.
      await auth.logout();
      await auth.setServerUrl(url);
      if (mounted) {
        setState(() => _message = '연결 설정을 적용했습니다. 로그인 화면에서 다시 로그인하세요.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = '설정을 적용하지 못했습니다. HTTPS 주소 또는 관리자 서명·유효기간을 확인하세요.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<AuthState>().isAdmin;
    return Scaffold(
      appBar: AppBar(title: const Text('업무 서버 연결 설정')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '이 기기의 연결 설정입니다. 최초 설치 또는 연결 장애 시 관리자가 제공한 서명된 설정 파일을 가져오세요. 적용하면 기존 세션은 종료됩니다.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _apply(fromFile: true),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('관리자 설정 파일 가져오기'),
          ),
          if (admin) ...[
            const SizedBox(height: 24),
            TextField(
              controller: _url,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'HTTPS 서버 주소',
                helperText: '관리자만 직접 변경할 수 있습니다.',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _apply(fromFile: false),
              child: const Text('적용 후 다시 로그인'),
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!),
            ),
        ],
      ),
    );
  }
}
