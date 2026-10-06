import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

/// 아이디·비밀번호처럼 영문만 받는 입력란용.
///
/// 한/영 키가 한글에 놓인 채 입력해도 같은 자판 위치의 영문이 들어가게 한다.
/// 두벌식 기준: 'ㅁ' → 'a', '안' → 'dks'.

const _initials = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
const _medials = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
const _finals = [
  '', 'ㄱ', 'ㄲ', 'ㄳ', 'ㄴ', 'ㄵ', 'ㄶ', 'ㄷ', 'ㄹ', 'ㄺ', 'ㄻ', 'ㄼ', 'ㄽ', //
  'ㄾ', 'ㄿ', 'ㅀ', 'ㅁ', 'ㅂ', 'ㅄ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ', 'ㅋ', 'ㅌ', //
  'ㅍ', 'ㅎ',
];

const _keys = {
  'ㄱ': 'r', 'ㄲ': 'R', 'ㄴ': 's', 'ㄷ': 'e', 'ㄸ': 'E', 'ㄹ': 'f', 'ㅁ': 'a', //
  'ㅂ': 'q', 'ㅃ': 'Q', 'ㅅ': 't', 'ㅆ': 'T', 'ㅇ': 'd', 'ㅈ': 'w', 'ㅉ': 'W', //
  'ㅊ': 'c', 'ㅋ': 'z', 'ㅌ': 'x', 'ㅍ': 'v', 'ㅎ': 'g', //
  'ㅏ': 'k', 'ㅐ': 'o', 'ㅑ': 'i', 'ㅒ': 'O', 'ㅓ': 'j', 'ㅔ': 'p', 'ㅕ': 'u', //
  'ㅖ': 'P', 'ㅗ': 'h', 'ㅛ': 'y', 'ㅜ': 'n', 'ㅠ': 'b', 'ㅡ': 'm', 'ㅣ': 'l', //
  'ㅘ': 'hk', 'ㅙ': 'ho', 'ㅚ': 'hl', 'ㅝ': 'nj', 'ㅞ': 'np', 'ㅟ': 'nl', //
  'ㅢ': 'ml', //
  'ㄳ': 'rt', 'ㄵ': 'sw', 'ㄶ': 'sg', 'ㄺ': 'fr', 'ㄻ': 'fa', 'ㄼ': 'fq', //
  'ㄽ': 'ft', 'ㄾ': 'fx', 'ㄿ': 'fv', 'ㅀ': 'fg', 'ㅄ': 'qt',
};

/// 한글(완성형 음절과 자모)을 두벌식 자판에서 같은 키의 영문으로 바꾼다.
String hangulToQwerty(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0xAC00 && rune <= 0xD7A3) {
      final code = rune - 0xAC00;
      out
        ..write(_keys[_initials[code ~/ 588]])
        ..write(_keys[_medials[(code % 588) ~/ 28]])
        ..write(_keys[_finals[code % 28]] ?? '');
    } else {
      final char = String.fromCharCode(rune);
      out.write(_keys[char] ?? char);
    }
  }
  return out.toString();
}

/// 입력란에 한글이 들어오면 영문으로 바꾼다. IME 가 글자를 조합하는 중에는
/// 손대지 않고, 조합이 끝난 뒤 바꾼다(조합 중에 바꾸면 글자가 겹친다).
class LatinInputFormatter extends TextInputFormatter {
  const LatinInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final converted = hangulToQwerty(newValue.text);
    if (converted == newValue.text) return newValue;
    final end = newValue.selection.isValid
        ? newValue.selection.end.clamp(0, newValue.text.length)
        : newValue.text.length;
    final offset = hangulToQwerty(newValue.text.substring(0, end)).length;
    return TextEditingValue(
      text: converted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

/// Windows: 지금 입력 중인 창의 IME 를 영문(영숫자) 모드로 바꾼다.
/// 한/영 키로 다시 바꿀 수 있으므로 [LatinInputFormatter] 와 함께 쓴다.
/// 다른 플랫폼이나 실패 시에는 아무것도 하지 않는다.
void switchImeToLatin() {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final imm32 = DynamicLibrary.open('imm32.dll');
    final getFocus = user32.lookupFunction<IntPtr Function(), int Function()>(
      'GetFocus',
    );
    final getContext = imm32
        .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
          'ImmGetContext',
        );
    final setConversion = imm32
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Uint32),
          int Function(int, int, int)
        >('ImmSetConversionStatus');
    final release = imm32
        .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
          'ImmReleaseContext',
        );
    final window = getFocus();
    if (window == 0) return;
    final context = getContext(window);
    if (context == 0) return;
    // IME_CMODE_ALPHANUMERIC(0), IME_SMODE_NONE(0)
    setConversion(context, 0, 0);
    release(window, context);
  } catch (_) {
    // IME 전환은 편의 기능이다. 실패해도 입력 변환기가 영문으로 바꾼다.
  }
}
