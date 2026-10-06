import 'package:flutter/services.dart';

/// 국내 전화번호에 하이픈을 넣는다. 입력 중인 일부 숫자도 자리에 맞게 끊는다.
///
/// * 휴대폰·지역번호·070: `010-1234-5678`, `031-123-4567`
/// * 서울: `02-123-4567`, `02-1234-5678`
/// * 대표번호(15xx·16xx·18xx): `1588-1234`
///
/// 숫자가 아닌 것(+82 같은 국제번호, 내선 표기)이 섞여 있거나 너무 길면
/// 잘못 고치지 않도록 그대로 둔다.
String formatPhoneNumber(String input) {
  final raw = input.trim();
  if (raw.isEmpty || RegExp(r'[^\d\s-]').hasMatch(raw)) return input;
  final d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty || d.length > 11) return input;

  String join(List<int> sizes) {
    final parts = <String>[];
    var at = 0;
    for (final size in sizes) {
      if (at >= d.length) break;
      final end = (at + size).clamp(0, d.length);
      parts.add(d.substring(at, end));
      at = end;
    }
    if (at < d.length) parts.add(d.substring(at));
    return parts.join('-');
  }

  if (d.startsWith('02')) {
    // 02-123-4567 (9자리) / 02-1234-5678 (10자리)
    return join(d.length <= 9 ? [2, 3, 4] : [2, 4, 4]);
  }
  if (RegExp(r'^1[5-9]').hasMatch(d) && d.length <= 8) {
    return join([4, 4]);
  }
  if (!d.startsWith('0')) return d.length <= 8 ? join([4, 4]) : input;
  // 010-1234-5678 (11자리) / 031-123-4567 (10자리)
  return join(d.length <= 10 ? [3, 3, 4] : [3, 4, 4]);
}

/// 연락처 입력란용: 숫자를 입력하는 대로 하이픈을 넣는다.
/// 기존에 '+82 …', '내선 3' 처럼 숫자 외 글자가 든 값은 손대지 않는다.
class PhoneNumberFormatter extends TextInputFormatter {
  const PhoneNumberFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (RegExp(r'[^\d\s-]').hasMatch(newValue.text)) return newValue;
    // 하이픈만 지운 경우(백스페이스가 하이픈에 걸림)에는 앞 숫자를 함께 지운다.
    var text = newValue.text.replaceAll(RegExp(r'\s'), '');
    final removedHyphenOnly =
        oldValue.text.length == newValue.text.length + 1 &&
        oldValue.text.replaceAll('-', '') == text.replaceAll('-', '');
    var cursorDigits = _digitsBefore(
      newValue.text,
      newValue.selection.isValid
          ? newValue.selection.end
          : newValue.text.length,
    );
    if (removedHyphenOnly && cursorDigits > 0) {
      final digits = text.replaceAll('-', '');
      text =
          digits.substring(0, cursorDigits - 1) +
          digits.substring(cursorDigits);
      cursorDigits -= 1;
    }
    final digits = text.replaceAll('-', '');
    if (digits.length > 11) return oldValue;
    final formatted = formatPhoneNumber(digits);
    // 커서는 그 앞에 있던 숫자 개수를 기준으로 다시 놓는다.
    var offset = 0;
    var seen = 0;
    while (offset < formatted.length && seen < cursorDigits) {
      if (formatted[offset] != '-') seen++;
      offset++;
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  static int _digitsBefore(String text, int end) => text
      .substring(0, end.clamp(0, text.length))
      .replaceAll(RegExp(r'\D'), '')
      .length;
}
