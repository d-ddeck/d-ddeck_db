import 'package:ddeck_app/services/alarm_prefs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'selected tone survives reload and all offered audio assets exist',
    () async {
      SharedPreferences.setMockInitialValues({});
      for (final tone in AlarmPrefs.tones.keys) {
        final prefs = AlarmPrefs()..tone = tone;
        await prefs.save();
        final restored = AlarmPrefs();
        await restored.load();
        expect(restored.tone, tone);
        final audio = await rootBundle.load(restored.audioPath);
        expect(audio.lengthInBytes, greaterThan(44));
      }
    },
  );
  test(
    'unknown or old tone preferences fall back to the original alarm',
    () async {
      SharedPreferences.setMockInitialValues({
        'calendar_alarm.tone': 'removed',
      });
      final prefs = AlarmPrefs();
      await prefs.load();
      expect(prefs.tone, 'alarm');
      expect(prefs.audioPath, 'assets/sounds/alarm.wav');
    },
  );
}
