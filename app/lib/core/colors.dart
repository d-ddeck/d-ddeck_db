import 'package:flutter/material.dart';

/// Parses "#RRGGBB" / "#AARRGGBB"; falls back to blue on anything unexpected
/// so a bad value in the code master cannot crash a screen.
Color parseHexColor(String hex, [Color fallback = const Color(0xFF3B82F6)]) {
  return tryParseHexColor(hex) ?? fallback;
}

Color? tryParseHexColor(String? hex) {
  if (hex == null) return null;
  var value = hex.trim().replaceFirst('#', '');
  if (value.length == 6) value = 'FF$value';
  if (value.length != 8) return null;
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? null : Color(parsed);
}
