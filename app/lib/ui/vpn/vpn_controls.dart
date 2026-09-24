import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../services/vpn_service.dart';
import '../../services/wireguard_config.dart';
import '../async_view.dart';
import '../theme.dart';
import 'vpn_qr_page.dart';

class VpnControls extends StatefulWidget {
  const VpnControls({super.key});

  @override
  State<VpnControls> createState() => _VpnControlsState();
}

class _VpnControlsState extends State<VpnControls> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String failure) async {
    final vpn = context.read<VpnService>();
    if (_busy || vpn.isBusy || vpn.state.isMoving) return;
    setState(() => _busy = true);
    try {
      await runGuarded(context, () async {
        try {
          await action();
        } catch (_) {
          // 파일·플러그인 예외에는 키가 섞일 수 있어 원문을 표시하지 않는다.
          throw ApiException(code: 'VPN_ERROR', message: failure);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 등록.
  ///
  /// 무엇을 가져올지 고르는 동안은 _run 밖이다. 사용자 응답을 기다리는 시간을
  /// "작업 중"으로 잡으면 진행 표시줄이 도는 채로 선택지를 묻게 되고, 실제로
  /// 진행 중인 것도 없다.
  Future<void> _register() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (VpnService.isSupported)
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('QR 촬영'),
                onTap: () => Navigator.pop(context, 'qr'),
              ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('설정 파일 가져오기'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;

    // QR 촬영도 사용자가 찍을 때까지 기다리는 일이라 밖에 둔다.
    WireguardConfig? scanned;
    if (source == 'qr') {
      scanned = await Navigator.of(context).push<WireguardConfig>(
        MaterialPageRoute(builder: (_) => const VpnQrPage()),
      );
      if (scanned == null || !mounted) return;
    }

    final config = scanned;
    await _run(() async {
      final vpn = context.read<VpnService>();
      if (config != null) {
        await vpn.register(config);
        return;
      }
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['conf'],
        withData: true,
      );
      if (result == null || !mounted) return;
      final file = result.files.single;
      final text = file.bytes != null
          ? utf8.decode(file.bytes!)
          : await File(file.path!).readAsString();
      if (!mounted) return;
      await vpn.register(WireguardConfig.parse(text));
    }, 'VPN 설정을 등록하지 못했습니다. QR 코드나 .conf 파일과 접근 권한을 확인해 주세요.');
  }

  Future<void> _unregister() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('VPN 등록 해제'),
        content: const Text('VPN 연결을 끄고 저장된 설정을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('등록 해제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      () => context.read<VpnService>().unregister(),
      'VPN 등록을 해제하지 못했습니다. 잠시 후 다시 시도해 주세요.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final vpn = context.watch<VpnService>();
    final scheme = Theme.of(context).colorScheme;
    final locked = _busy || vpn.isBusy || vpn.state.isMoving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!vpn.isRegistered) ...[
          const Text('사외에서 접속하려면 VPN 등록이 필요합니다'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: locked ? null : _register,
            icon: const Icon(Icons.vpn_key_outlined),
            label: const Text('VPN 등록'),
          ),
        ] else
          Row(
            children: [
              StatusChip(
                label: '사외 접속(VPN)',
                icon: vpn.state.isOn ? Icons.check : Icons.vpn_key_outlined,
                color: vpn.state.isOn ? scheme.primary : scheme.outline,
                dense: true,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${vpn.state.label}${vpn.endpoint == null ? '' : ' · ${vpn.endpoint}'}',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (vpn.state.isMoving)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  value: vpn.state.isOn,
                  onChanged: locked
                      ? null
                      : (_) => _run(vpn.toggle,
                          'VPN 연결을 변경하지 못했습니다. 잠시 후 다시 시도해 주세요.'),
                ),
              PopupMenuButton<String>(
                tooltip: 'VPN 관리',
                enabled: !locked,
                onSelected: (_) => _unregister(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'unregister', child: Text('VPN 등록 해제')),
                ],
              ),
            ],
          ),
        if (_busy) const LinearProgressIndicator(),
        if (vpn.error != null) ...[
          const SizedBox(height: 4),
          Text(vpn.error!, style: TextStyle(fontSize: 12, color: scheme.error)),
        ],
      ],
    );
  }
}
