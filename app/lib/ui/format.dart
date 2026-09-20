import 'package:intl/intl.dart';

/// Shared formatters. Timestamps arrive as UTC and are already converted to
/// local by the model layer, so these only deal with presentation.
class Fmt {
  static final _date = DateFormat('yyyy-MM-dd');
  static final _dateTime = DateFormat('yyyy-MM-dd HH:mm');
  static final _time = DateFormat('HH:mm');
  static final _monthDay = DateFormat('M월 d일');
  static final _money = NumberFormat('#,##0');
  static final _decimal = NumberFormat('#,##0.##');

  static String date(DateTime? d) => d == null ? '-' : _date.format(d);
  static String dateTime(DateTime? d) => d == null ? '-' : _dateTime.format(d);
  static String time(DateTime? d) => d == null ? '-' : _time.format(d);
  static String monthDay(DateTime? d) => d == null ? '-' : _monthDay.format(d);

  static String money(num? v) => v == null ? '-' : '${_money.format(v)}원';
  static String number(num? v) => v == null ? '-' : _decimal.format(v);
  static String percent(double? ratio, {int digits = 1}) =>
      ratio == null ? '-' : '${(ratio * 100).toStringAsFixed(digits)}%';

  /// Minutes -> "3시간 20분". The statistics API returns durations in minutes.
  static String duration(num? minutes) {
    if (minutes == null) return '-';
    final total = minutes.round();
    if (total < 60) return '$total분';
    final h = total ~/ 60;
    final m = total % 60;
    if (h < 24) return m == 0 ? '$h시간' : '$h시간 $m분';
    final d = h ~/ 24;
    return '$d일 ${h % 24}시간';
  }

  /// "3분 전" / "어제" style, for notification and comment lists.
  static String relative(DateTime? d) {
    if (d == null) return '-';
    final diff = DateTime.now().difference(d);
    if (diff.isNegative) return _dateTime.format(d);
    if (diff.inMinutes < 1) return '방금';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    if (diff.inHours < 24) return '${diff.inHours}시간 전';
    if (diff.inDays == 1) return '어제';
    if (diff.inDays < 7) return '${diff.inDays}일 전';
    return _date.format(d);
  }

  /// Event time range, collapsing a same-day range to "14:00 ~ 15:30".
  static String range(DateTime start, DateTime end, {bool allDay = false}) {
    if (allDay) return '${_date.format(start)} (종일)';
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    if (sameDay) {
      return '${_dateTime.format(start)} ~ ${_time.format(end)}';
    }
    return '${_dateTime.format(start)} ~ ${_dateTime.format(end)}';
  }
}
