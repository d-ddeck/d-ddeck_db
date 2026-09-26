import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../common/common.dart';

import '../../services/wireguard_config.dart';

class VpnQrPage extends StatefulWidget {
  const VpnQrPage({super.key});

  @override
  State<VpnQrPage> createState() => _VpnQrPageState();
}

class _VpnQrPageState extends State<VpnQrPage> {
  bool _completed = false;
  String? _message;

  void _onDetect(BarcodeCapture capture) {
    if (!mounted || _completed) return;
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode) continue;
      final text = barcode.rawValue;
      if (text == null) continue;
      try {
        // 비밀키가 담긴 QR 원문은 상태나 경로 인자로 보관하지 않고 즉시 파싱한다.
        final config = WireguardConfig.parse(text);
        _completed = true;
        Navigator.of(context).pop(config);
        return;
      } on WireguardConfigException {
        if (_message == null) {
          setState(() => _message = 'WireGuard 설정 QR 이 아닙니다');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('QR 촬영')),
    body: PageBody(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: !Platform.isAndroid
              ? const EmptyState(
                  icon: Icons.qr_code,
                  message: 'QR 촬영은 안드로이드에서 사용할 수 있습니다.',
                )
              : Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('공유기에서 발급받은 WireGuard 설정 QR 코드를 비춰 주세요.'),
                    ),
                    Expanded(
                      child: MobileScanner(
                        onDetect: _onDetect,
                        errorBuilder: (context, error) => ErrorState(
                          message:
                              error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied
                              ? '카메라 권한이 필요합니다. 기기 설정에서 카메라 권한을 허용한 뒤 다시 열어 주세요.'
                              : '카메라를 사용할 수 없습니다. 잠시 후 다시 열어 주세요.',
                        ),
                      ),
                    ),
                    if (_message != null)
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _message!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    ),
  );
}
