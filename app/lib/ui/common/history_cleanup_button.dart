import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/api_client.dart';
import '../../state/auth_state.dart';
import 'common.dart';

/// The server independently checks the resolved client IP and administrator role.
class HistoryCleanupButton extends StatelessWidget {
  const HistoryCleanupButton({
    super.key,
    required this.kind,
    required this.id,
    required this.onChanged,
  });
  final String kind, id;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final host = Uri.tryParse(auth.serverUrl)?.host;
    if (!auth.isAdmin || !['localhost', '127.0.0.1', '::1'].contains(host)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.delete_outline),
      tooltip: '이력 한 줄 정리',
      onPressed: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('이력 목록에서 제거할까요?'),
            content: const Text('원본과 재고 계산에 필요한 참조는 보존됩니다. 정리한 관리자도 기록됩니다.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('목록에서 제거'),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        if (await runGuarded(
          context,
          () => context.read<ApiClient>().delete('/admin/history/$kind/$id'),
        )) {
          onChanged();
        }
      },
    );
  }
}
