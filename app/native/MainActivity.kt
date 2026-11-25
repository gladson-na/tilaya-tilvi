package PKG_NAME

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tilda/native")
        TildaService.onFocus = { f -> ch.invokeMethod("focus", f) }
        TildaService.onTap = { ch.invokeMethod("toggle", null) }
        ch.setMethodCallHandler { call, res ->
            when (call.method) {
                "insert" -> res.success(TildaService.insert(call.arguments as String))
                "liveStart" -> res.success(TildaService.liveStart())
                "liveSet" -> res.success(TildaService.liveSet(call.arguments as String))
                "state" -> { TildaService.instance?.setState(call.arguments as String); res.success(true) }
                "auto" -> { TildaService.auto = call.arguments as Boolean; res.success(true) }
                "enabled" -> res.success(TildaService.instance != null)
                "settings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    res.success(true)
                }
                else -> res.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        TildaService.onFocus = null
        TildaService.onTap = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
