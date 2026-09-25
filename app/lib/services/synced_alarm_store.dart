import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/calendar.dart';

class SyncedAlarmSnapshot {
  const SyncedAlarmSnapshot({this.syncedAt, this.reminders = const []});
  final DateTime? syncedAt;
  final List<UpcomingReminder> reminders;
}

class SyncedAlarmStore {
  static const _key = 'calendar_alarm.synced';

  Future<SyncedAlarmSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const SyncedAlarmSnapshot();
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return SyncedAlarmSnapshot(
      syncedAt: DateTime.parse(data['synced_at'] as String).toLocal(),
      reminders: (data['reminders'] as List).map((r) =>
        UpcomingReminder.fromJson(Map<String, dynamic>.from(r as Map))).toList(),
    );
  }

  Future<void> save(List<UpcomingReminder> reminders) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_key, jsonEncode({
      'synced_at': DateTime.now().toUtc().toIso8601String(),
      'reminders': reminders.map((r) => r.toJson()).toList(),
    }));
    if (!saved) throw StateError('동기화된 알람을 저장하지 못했습니다.');
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_key)) throw StateError('저장된 알람을 지우지 못했습니다.');
  }
}
