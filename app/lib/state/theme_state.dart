import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device preference; retained across logout and restored before the first frame.
class ThemeState extends ChangeNotifier {
  static const preferenceKey = 'appearance.theme_mode';
  ThemeMode _mode = ThemeMode.system;
  bool compact = false;
  Future<void> setCompact(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool('appearance.compact', value)) {
      throw StateError('목록 밀도 저장 실패');
    }
    compact = value;
    notifyListeners();
  }

  ThemeMode get mode => _mode;
  bool _saving = false;
  bool get saving => _saving;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      compact = prefs.getBool('appearance.compact') ?? false;
      final saved = prefs.getString(preferenceKey);
      _mode =
          ThemeMode.values.where((m) => m.name == saved).firstOrNull ??
          ThemeMode.system;
    } catch (_) {
      _mode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> select(ThemeMode mode) async {
    if (_saving || mode == _mode) return;
    _saving = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(preferenceKey, mode.name)) {
        throw StateError('화면 모드 저장 실패');
      }
      _mode = mode;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}
