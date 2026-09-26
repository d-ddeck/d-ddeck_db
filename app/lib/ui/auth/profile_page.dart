import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/auth_repository.dart';
import '../../state/auth_state.dart';
import '../common/common.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final _name = TextEditingController(
    text: context.read<AuthState>().user?.fullName,
  );
  late final _phone = TextEditingController(
    text: context.read<AuthState>().user?.phone,
  );
  late final _position = TextEditingController(
    text: context.read<AuthState>().user?.position,
  );
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DirtyFormScope(
    busy: _busy,
    snapshot: () => [_name.text, _phone.text, _position.text].toString(),
    child: Scaffold(
      appBar: AppBar(title: const Text('내 정보 수정')),
      body: PageBody(
        child: ListView(
          children: [
            for (final field in [
              (_name, '이름'),
              (_phone, '전화번호'),
              (_position, '직급'),
            ])
              TextField(
                controller: field.$1,
                decoration: InputDecoration(labelText: field.$2),
              ),
            const FormGap(),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      if (_name.text.trim().isEmpty) {
                        AppSnack.show(context, '이름을 입력하세요.');
                        return;
                      }
                      setState(() => _busy = true);
                      final auth = context.read<AuthState>();
                      final ok = await runGuarded(context, () async {
                        await context.read<AuthRepository>().updateMe(
                          fullName: _name.text.trim(),
                          phone: _phone.text.trim(),
                          position: _position.text.trim(),
                        );
                        await auth.refreshProfile();
                      }, successMessage: '내 정보를 저장했습니다.');
                      if (!mounted || !context.mounted) return;
                      setState(() => _busy = false);
                      if (ok) Navigator.pop(context);
                    },
              child: Text(_busy ? '저장 중…' : '저장'),
            ),
          ],
        ),
      ),
    ),
  );
}
