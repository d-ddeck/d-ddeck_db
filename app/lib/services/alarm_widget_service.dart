import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native widget reads SyncedAlarmStore's durable snapshot directly.
class AlarmWidgetService {
  static const channel = MethodChannel('ddeck/alarm_widget');
  static final launch = ValueNotifier<String?>(null);
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> initialize() async {
    if (!supported) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'launchAvailable') await takeLaunch();
    });
    await takeLaunch();
    await refresh();
  }

  static Future<void> takeLaunch() async {
    if (!supported) return;
    try {
      final id = await channel.invokeMethod<String>('takeLaunch');
      if (id != null) launch.value = id;
    } on PlatformException catch (_) {
      // Widget navigation must not prevent normal app startup.
    } on MissingPluginException catch (_) {}
  }

  static Future<void> refresh() async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('refresh');
    } on PlatformException catch (_) {
      // The snapshot is durable; launcher periodic refresh can recover.
    } on MissingPluginException catch (_) {}
  }
}
