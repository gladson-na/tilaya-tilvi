package PKG_NAME

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * Optional "Keep listening in the background" (off by default, switched on in Settings).
 * A foreground service with a visible notification keeps the phone's own speech engine waiting for "Hey Tilda".
 * While the Tilda screen is open the Flutter side owns the microphone, so this service pauses itself.
 */
class WakeService : Service() {
    companion object {
        @Volatile var running = false
        @Volatile var paused = true
        @Volatile var extra: List<String> = emptyList() // how this person's phone wrote the call, learned in setup
        @Volatile var pendingText: String? = null
        var onWake: (() -> Unit)? = null

        private const val NAME = "(?:[td][iyeu]l+[dt]?[aeu]r?|hilda|hilder|[टत]िल्?[डद][ाेा]?)"
        private const val CALLS = "(?:hey|hi|hello|ae|ay|aye|eh|a|oye|oi|o|oh|arre|are|suno|ok|okay|हे|हेलो|ए|ऐ|ओय|ओ|अरे|सुनो|ओके)"

        fun called(text: String): Boolean {
            val learned = extra.filter { it.isNotBlank() }.joinToString("|") { Regex.escape(it.trim().lowercase()) }
            val heard = if (learned.isEmpty()) "" else "(?:$learned)|"
            return Regex("^\\s*(?:\\S+\\s+)?(?:$heard(?:$CALLS[\\s,.!?-]+)?$NAME)(?=[\\s,.!?-]|\\$)", RegexOption.IGNORE_CASE)
                .containsMatchIn(text.trim().lowercase())
        }
    }

    private val h = Handler(Looper.getMainLooper())
    private var rec: SpeechRecognizer? = null
    private var live = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") { stopSelf(); return START_NOT_STICKY }
        val ch = "tilda_wake"
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel(ch, "Tilda listening", NotificationManager.IMPORTANCE_LOW))
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 1, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 2, Intent(this, WakeService::class.java).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, ch) else Notification.Builder(this)
        @Suppress("DEPRECATION")
        val n = b.setContentTitle("Tilda is listening")
            .setContentText("Say \"Hey Tilda\". Tap to open.")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pi)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Turn off", stop)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(8, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) else startForeground(8, n)
        } catch (_: Exception) { stopSelf(); return START_NOT_STICKY }
        running = true
        if (!live) { live = true; h.post { loop() } }
        return START_STICKY
    }

    private fun lang(): String =
        try { getSharedPreferences("tilda_native", Context.MODE_PRIVATE).getString("lang", "en-IN") ?: "en-IN" } catch (_: Exception) { "en-IN" }

    private fun later(ms: Long) { h.removeCallbacksAndMessages(null); h.postDelayed({ loop() }, ms) }

    private fun drop() {
        try { rec?.cancel() } catch (_: Exception) {}
        try { rec?.destroy() } catch (_: Exception) {}
        rec = null
    }

    private fun loop() {
        if (!running) return
        if (paused || !SpeechRecognizer.isRecognitionAvailable(this)) { drop(); later(1000); return }
        drop()
        try {
            val r = SpeechRecognizer.createSpeechRecognizer(this)
            rec = r
            r.setRecognitionListener(object : RecognitionListener {
                private var woke = false
                private fun check(b: Bundle?) {
                    if (woke || paused) return
                    val all = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: return
                    val hit = all.firstOrNull { called(it) } ?: return
                    woke = true
                    heard(hit)
                }
                override fun onPartialResults(b: Bundle?) = check(b)
                override fun onResults(b: Bundle?) { check(b); if (!woke) later(300) }
                override fun onError(e: Int) {
                    if (woke) return
                    later(if (e == SpeechRecognizer.ERROR_RECOGNIZER_BUSY || e == SpeechRecognizer.ERROR_CLIENT) 1500 else 400)
                }
                override fun onReadyForSpeech(p: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(v: Float) {}
                override fun onBufferReceived(b: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(t: Int, b: Bundle?) {}
            })
            r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang())
                .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName))
        } catch (_: Exception) { later(2000) }
    }

    /** "Hey Tilda" was heard: bring Tilda to the front and let it carry on from the words. */
    private fun heard(text: String) {
        drop()
        pendingText = text
        try {
            val i = packageManager.getLaunchIntentForPackage(packageName)?.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            if (i != null) {
                // the typing service is allowed to open screens from the background; this service on its own is not
                val a = TildaService.instance
                if (a != null) a.startActivity(i) else startActivity(i)
            }
        } catch (_: Exception) {}
        onWake?.invoke()
        paused = true // the app screen owns the microphone now; it un-pauses us when it goes away
        later(1500)
    }

    override fun onDestroy() {
        running = false
        live = false
        h.removeCallbacksAndMessages(null)
        drop()
        super.onDestroy()
    }
}
