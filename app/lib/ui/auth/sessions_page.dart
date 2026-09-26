import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/auth_repository.dart';
import '../../models/common.dart';
import '../async_view.dart';
import '../common/common.dart';
import '../format.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final repo = context.read<AuthRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('로그인 기기·세션')),
      body: PageBody(
        child: AsyncView<List<Map<String, dynamic>>>(
          load: repo.sessions,
          builder: (context, rows, reload) => ListView(
            children: [
              const Text('세션을 종료하면 해당 기기는 다시 로그인해야 합니다.'),
              for (final row in rows)
                ListTile(
                  title: Text(asString(row['user_agent'], '기기 정보 없음')),
                  subtitle: Text(
                    '${asString(row['ip_address'])} · ${Fmt.dateTime(asDate(row['created_at']))}',
                  ),
                  trailing: row['revoked_at'] != null
                      ? const Text('종료됨')
                      : TextButton(
                          child: const Text('종료'),
                          onPressed: () async {
                            if (!await ConfirmDialog.show(
                              context,
                              title: '세션 종료',
                              message: '이 기기의 로그인을 종료하시겠습니까?',
                              confirmLabel: '종료',
                            )) {
                              return;
                            }
                            if (!context.mounted) return;
                            final ok = await runGuarded(
                              context,
                              () => repo.revokeSession(asString(row['id'])),
                            );
                            if (context.mounted && ok) {
                              await runGuarded(context, () async {
                                await context.read<AuthRepository>().me();
                              });
                              if (context.mounted) reload();
                            }
                          },
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
