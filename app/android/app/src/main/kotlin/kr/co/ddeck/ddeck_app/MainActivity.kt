package kr.co.ddeck.ddeck_app

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ddeck/updates")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "canInstall" -> result.success(Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls())
                        "requestInstallPermission" -> {
                            if (Build.VERSION.SDK_INT >= 26) {
                                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("INSTALL_PERMISSION", "설치 권한 설정을 열 수 없습니다.", null)
                }
            }
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
