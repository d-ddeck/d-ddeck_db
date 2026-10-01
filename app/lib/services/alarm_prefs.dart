import 'package:shared_preferences/shared_preferences.dart';

class AlarmPrefs {
  bool enabled = true;
  bool sound = true;
  static const tones = {'alarm': '기본 알람', 'chime': '맑은 벨', 'gentle': '부드러운 알림'};
  String tone = 'alarm';
  String get audioPath =>
      'assets/sounds/${tones.containsKey(tone) ? tone : 'alarm'}.wav';
  bool vibrate = true;
  double volume = 0.8;
  int snoozeMinutes = 5;
  bool get loopAudio => true;

  Future<void> load() async {
    final store = await SharedPreferences.getInstance();
    enabled = store.getBool('calendar_alarm.enabled') ?? true;
    sound = store.getBool('calendar_alarm.sound') ?? true;
    final savedTone = store.getString('calendar_alarm.tone');
    tone = tones.containsKey(savedTone) ? savedTone! : 'alarm';
    vibrate = store.getBool('calendar_alarm.vibrate') ?? true;
    volume = (store.getDouble('calendar_alarm.volume') ?? 0.8).clamp(0.0, 1.0);
    final minutes = store.getInt('calendar_alarm.snooze') ?? 5;
    snoozeMinutes = [1, 3, 5, 10].contains(minutes) ? minutes : 5;
  }

  Future<void> save() async {
    final store = await SharedPreferences.getInstance();
    await store.setBool('calendar_alarm.enabled', enabled);
    await store.setBool('calendar_alarm.sound', sound);
    await store.setString('calendar_alarm.tone', tone);
    await store.setBool('calendar_alarm.vibrate', vibrate);
    await store.setDouble('calendar_alarm.volume', volume.clamp(0.0, 1.0));
    await store.setInt('calendar_alarm.snooze', snoozeMinutes);
  }
}
