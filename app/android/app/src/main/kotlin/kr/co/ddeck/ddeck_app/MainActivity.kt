package kr.co.ddeck.ddeck_app

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ddeck/alarm_permissions")
            .setMethodCallHandler { call, result ->
                if (call.method == "fullScreenAllowed") {
                    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    result.success(Build.VERSION.SDK_INT < 34 || manager.canUseFullScreenIntent())
                } else {
                    result.notImplemented()
                }
            }
    }
}
