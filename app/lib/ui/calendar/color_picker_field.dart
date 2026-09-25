import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../format.dart';
import '../theme.dart';

class EventColorField extends StatelessWidget {
  const EventColorField({super.key, required this.value, required this.defaultColor,
    required this.onChanged, required this.title, required this.startsAt,
    required this.endsAt, required this.allDay, this.existingColor,
    this.canceled = false});

  final String? value, existingColor;
  final Color defaultColor;
  final ValueChanged<String?> onChanged;
  final String title;
  final DateTime startsAt, endsAt;
  final bool allDay, canceled;

  static const _palette = [
    ('파랑', '#3B82F6'), ('하늘', '#0EA5E9'), ('청록', '#14B8A6'),
    ('초록', '#22C55E'), ('라임', '#84CC16'), ('노랑', '#EAB308'),
    ('주황', '#F97316'), ('빨강', '#EF4444'), ('분홍', '#EC4899'),
    ('보라', '#8B5CF6'), ('남색', '#6366F1'), ('회색', '#64748B'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final custom = existingColor?.trim().toUpperCase();
    final selected = value?.trim().toUpperCase();
    final color = canceled ? Colors.grey
        : value == null ? defaultColor : parseHexColor(value!, defaultColor);
    final lastDay = DateUtils.dateOnly(endsAt.subtract(const Duration(microseconds: 1)));
    final solid = allDay || lastDay.isAfter(DateUtils.dateOnly(startsAt));
    final background = Color.alphaBlend(solid ? color : color.withValues(alpha: 0.16), scheme.surface);
    final foreground = background.computeLuminance() > 0.179 ? Colors.black : Colors.white;
    final previewTitle = title.isEmpty ? '제목' : title;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('표시 색', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
          color: AppColors.muted(context))),
        const SizedBox(width: AppSpace.md),
        Flexible(child: Semantics(label: '일정 색 미리보기', child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
          decoration: BoxDecoration(color: background,
            borderRadius: BorderRadius.circular(AppRadius.sm)),
          child: Text(solid ? previewTitle : '${Fmt.time(startsAt)} $previewTitle',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: foreground,
              decoration: canceled ? TextDecoration.lineThrough : null,
              decorationColor: foreground)),
        ))),
      ]),
      const SizedBox(height: AppSpace.sm),
      Wrap(spacing: AppSpace.xs, runSpacing: AppSpace.sm,
        crossAxisAlignment: WrapCrossAlignment.center, children: [
          Tooltip(message: '기본(캘린더 색)', child: ChoiceChip(
            label: const Text('기본(캘린더 색)'),
            selected: value == null,
            showCheckmark: true,
            side: BorderSide(color: value == null ? scheme.primary : scheme.outlineVariant,
              width: value == null ? 2 : 1),
            onSelected: (_) => onChanged(null),
          )),
          for (final (name, hex) in _palette)
            _chip(context, name, hex, selected == hex),
          if (custom != null && custom.isNotEmpty && !_palette.any((entry) => entry.$2 == custom))
            _chip(context, '기존 색 ($custom)', custom, selected == custom),
        ]),
    ]);
  }

  Widget _chip(BuildContext context, String name, String hex, bool selected) {
    final color = parseHexColor(hex);
    final foreground = color.computeLuminance() > 0.179 ? Colors.black : Colors.white;
    return Semantics(button: true, selected: selected, label: name,
      child: Tooltip(message: name, child: Material(color: color, shape: CircleBorder(
        side: BorderSide(color: selected ? Theme.of(context).colorScheme.onSurface
            : Theme.of(context).colorScheme.outlineVariant, width: selected ? 3 : 1)),
        child: InkWell(customBorder: const CircleBorder(), onTap: () => onChanged(hex),
          child: SizedBox(width: 32, height: 32,
            child: selected ? Icon(Icons.check, size: 20, color: foreground) : null)),
      )),
    );
  }
}
