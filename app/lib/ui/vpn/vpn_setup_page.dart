import 'package:flutter/material.dart';

import 'vpn_controls.dart';

class VpnSetupPage extends StatelessWidget {
  const VpnSetupPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('사외 접속(VPN) 설정')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: const [
            Text(
              '외근·재택 중 사내 서버를 사용하려면 VPN 연결이 필요합니다.\n'
              '공유기 관리자에게 이 기기용 QR 코드나 .conf 파일을 받아 주세요.',
            ),
            SizedBox(height: 20),
            VpnControls(),
          ],
        ),
      ),
    ),
  );
}
