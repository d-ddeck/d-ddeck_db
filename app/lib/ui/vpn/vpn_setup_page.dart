import 'package:flutter/material.dart';
import '../common/common.dart';

import 'vpn_controls.dart';

class VpnSetupPage extends StatelessWidget {
  const VpnSetupPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('사외 접속(VPN) 설정')),
    body: PageBody(child: Center(child: SingleChildScrollView(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
        child: const SectionCard(title: 'VPN 설정', child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('외근·재택 중 사내 서버를 사용하려면 VPN 연결이 필요합니다.\n'
              '공유기 관리자에게 이 기기용 QR 코드나 .conf 파일을 받아 주세요.'),
            FormGap(), VpnControls(),
          ],
        )),
      ),
    ))),
  );
}
