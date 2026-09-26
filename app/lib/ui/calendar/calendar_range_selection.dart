import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class CalendarRangeSelection extends StatefulWidget {
  const CalendarRangeSelection({
    super.key,
    required this.child,
    required this.firstDay,
    required this.rowHeight,
    required this.weeks,
    required this.enabled,
    required this.onSelected,
  });
  final Widget child;
  final DateTime firstDay;
  final double rowHeight;
  final int weeks;
  final bool enabled;
  final void Function(DateTime start, DateTime end) onSelected;
  @override
  State<CalendarRangeSelection> createState() => _CalendarRangeSelectionState();
}

class _CalendarRangeSelectionState extends State<CalendarRangeSelection> {
  int? _start, _end;
  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 8) / 7;
        int? cell(Offset point) {
          final col = ((point.dx - 4) / width).floor(),
              row = ((point.dy - 22) / widget.rowHeight).floor();
          if (col < 0 || col > 6 || row < 0 || row >= widget.weeks) return null;
          return row * 7 + col;
        }

        final low = _start == null || _end == null
            ? -1
            : (_start! < _end! ? _start! : _end!);
        final high = _start == null || _end == null
            ? -1
            : (_start! > _end! ? _start! : _end!);
        return GestureDetector(
          dragStartBehavior: DragStartBehavior.down,
          behavior: HitTestBehavior.translucent,
          onPanStart: (event) => setState(() {
            _start = cell(event.localPosition);
            _end = _start;
          }),
          onPanUpdate: (event) {
            final next = cell(event.localPosition);
            if (next != null) setState(() => _end = next);
          },
          onPanCancel: () => setState(() {
            _start = null;
            _end = null;
          }),
          onPanEnd: (_) {
            if (low >= 0 && high > low) {
              widget.onSelected(
                DateTime(
                  widget.firstDay.year,
                  widget.firstDay.month,
                  widget.firstDay.day + low,
                ),
                DateTime(
                  widget.firstDay.year,
                  widget.firstDay.month,
                  widget.firstDay.day + high,
                ),
              );
            }
            setState(() {
              _start = null;
              _end = null;
            });
          },
          child: Stack(
            children: [
              widget.child,
              if (low >= 0)
                for (var day = low; day <= high; day++)
                  Positioned(
                    left: 4 + (day % 7) * width,
                    top: 22 + (day ~/ 7) * widget.rowHeight,
                    width: width,
                    height: widget.rowHeight,
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .16),
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}
