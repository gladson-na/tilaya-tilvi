package PKG_NAME

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4242) return
        val r = pending ?: return
        pending = null
        if (resultCode == RESULT_OK && data != null) {
            try {
                val i = Intent(this, NotesService::class.java).putExtra("code", resultCode).putExtra("data", data)
                if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                r.success(true)
            } catch (e: Exception) { r.success(false) }
        } else r.success(false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tilda/native")
        TildaService.onFocus = { f -> ch.invokeMethod("focus", f) }
        TildaService.onTap = { ch.invokeMethod("toggle", null) }
        TildaService.onLongPress = { ch.invokeMethod("longpress", null) }
        NotesService.onControl = { what -> runOnUiThread { ch.invokeMethod("notesCtl", what) } }
        ch.setMethodCallHandler { call, res ->
            when (call.method) {
                "insert" -> res.success(TildaService.insert(call.arguments as String))
                "label" -> { TildaService.label(call.arguments as String); res.success(true) }
                "liveStart" -> res.success(TildaService.liveStart())
                "liveSet" -> res.success(TildaService.liveSet(call.arguments as String))
                "state" -> { TildaService.instance?.setState(call.arguments as String); res.success(true) }
                "lang" -> { TildaService.saveLang(this, call.arguments as String); res.success(true) }
                "auto" -> { TildaService.auto = call.arguments as Boolean; res.success(true) }
                "enabled" -> res.success(TildaService.instance != null)
                "notesOn" -> {
                    try {
                        val i = Intent(this, NotesService::class.java)
                        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                        res.success(true)
                    } catch (e: Exception) { res.success(false) }
                }
                "captureStart" -> {
                    if (android.os.Build.VERSION.SDK_INT < 29) res.success(false)
                    else try {
                        pending = res
                        val m = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        startActivityForResult(m.createScreenCaptureIntent(), 4242)
                    } catch (e: Exception) { pending = null; res.success(false) }
                }
                "captureTake" -> res.success(NotesService.take())
                "captureLevel" -> res.success(NotesService.level)
                "notesPaused" -> { NotesService.syncPaused(call.arguments as Boolean); res.success(true) }
                "notesOff" -> { stopService(Intent(this, NotesService::class.java)); res.success(true) }
                "toBack" -> { moveTaskToBack(true); res.success(true) }
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
        TildaService.onLongPress = null
        NotesService.onControl = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
