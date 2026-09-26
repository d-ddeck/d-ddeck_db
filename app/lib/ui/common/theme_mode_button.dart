import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/theme_state.dart';

class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({super.key});

  static String label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '시스템 설정',
    ThemeMode.light => '라이트 모드',
    ThemeMode.dark => '다크 모드',
  };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ThemeState>();
    return PopupMenuButton<ThemeMode>(
      tooltip: '화면 모드: ${label(state.mode)}',
      enabled: !state.saving,
      icon: Icon(switch (state.mode) {
        ThemeMode.system => Icons.brightness_auto_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      }),
      itemBuilder: (_) => [
        for (final mode in ThemeMode.values)
          CheckedPopupMenuItem(
            value: mode,
            checked: state.mode == mode,
            child: Text(label(mode)),
          ),
      ],
      onSelected: (mode) async {
        try {
          await state.select(mode);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('화면 모드를 저장하지 못했습니다. 다시 시도해 주세요.')),
            );
          }
        }
      },
    );
  }
}
