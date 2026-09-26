import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Firebase configuration is supplied by the deployment build, never a service key.
class PushService {
  StreamSubscription<String>? _refresh;
  int _generation = 0;
  static const _project = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _app = String.fromEnvironment('FIREBASE_APP_ID');
  static const _key = String.fromEnvironment('FIREBASE_API_KEY');
  static const _sender = String.fromEnvironment('FIREBASE_SENDER_ID');

  Future<void> start(Future<void> Function(String) register) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        [_project, _app, _key, _sender].any((s) => s.isEmpty)) {
      return;
    }
    final generation = ++_generation;
    await _refresh?.cancel();
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: _key,
            appId: _app,
            messagingSenderId: _sender,
            projectId: _project,
          ),
        );
      }
      final messaging = FirebaseMessaging.instance;
      final permission = await messaging.requestPermission();
      if (permission.authorizationStatus == AuthorizationStatus.denied ||
          generation != _generation) {
        return;
      }
      final token = await messaging.getToken();
      if (generation != _generation) return;
      if (token != null) await register(token);
      if (generation != _generation) return;
      _refresh = messaging.onTokenRefresh.listen((token) async {
        if (generation != _generation) return;
        try {
          await register(token);
        } catch (_) {
          /* Retry next login/profile refresh. */
        }
      });
    } catch (_) {
      /* In-app notifications remain available without Firebase. */
    }
  }

  void stop() {
    _generation++;
    unawaited(_refresh?.cancel());
    _refresh = null;
  }
}
