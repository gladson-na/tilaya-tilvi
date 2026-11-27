package PKG_NAME

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Shader
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import android.animation.ValueAnimator
import java.io.ByteArrayOutputStream

/**
 * Keeps notes alive in the background. With a screen-capture permission it records the phone's own sound
 * (any app, any volume, Bluetooth or not) as 16 kHz mono; always shows a soft blue glow over other apps.
 */
class NotesService : Service() {
    companion object {
        private val buf = ByteArrayOutputStream()
        @Volatile var level = 0.0
        @Volatile var capturing = false
        @Volatile var notesRunning = false
        fun take(): ByteArray = synchronized(buf) { val b = buf.toByteArray(); buf.reset(); b }
    }

    private var proj: MediaProjection? = null
    private var rec: AudioRecord? = null
    private var worker: Thread? = null
    private var glow: GlowView? = null
    private var anim: ValueAnimator? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val ch = "tilda_notes"
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel(ch, "Tilda notes", NotificationManager.IMPORTANCE_LOW))
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, ch) else Notification.Builder(this)
        val n = b.setContentTitle("Tilda notes running")
            .setContentText("Tap to go back to your notes")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        val code = intent?.getIntExtra("code", 0) ?: 0
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra<Intent>("data")
        val micOnly = intent?.getBooleanExtra("micOnly", false) == true
        if (!micOnly) notesRunning = true
        val wantCapture = data != null && Build.VERSION.SDK_INT >= 29
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(7, n, if (wantCapture || capturing) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else startForeground(7, n)
        if (wantCapture && !capturing) startCapture(code, data!!)
        if (!micOnly) showGlow()
        return START_STICKY
    }

    private fun startCapture(code: Int, data: Intent) {
        try {
            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val mp = mgr.getMediaProjection(code, data) ?: throw IllegalStateException("no projection")
            mp.registerCallback(object : MediaProjection.Callback() { override fun onStop() { capturing = false } }, null)
            proj = mp
            val cfg = AudioPlaybackCaptureConfiguration.Builder(mp)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val fmt = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(48000)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()
            val r = AudioRecord.Builder().setAudioFormat(fmt).setAudioPlaybackCaptureConfig(cfg)
                .setBufferSizeInBytes(48000 * 2).build()
            rec = r
            r.startRecording()
            capturing = true
            synchronized(buf) { buf.reset() }
            worker = Thread {
                val raw = ShortArray(4800)
                while (capturing) {
                    val k = r.read(raw, 0, raw.size)
                    if (k <= 0) continue
                    // 48 kHz to 16 kHz: average every three samples
                    val out = ByteArray((k / 3) * 2)
                    var sum = 0.0
                    var o = 0
                    var i = 0
                    while (i + 2 < k) {
                        val v = (raw[i] + raw[i + 1] + raw[i + 2]) / 3
                        out[o++] = (v and 0xFF).toByte()
                        out[o++] = ((v shr 8) and 0xFF).toByte()
                        sum += v.toDouble() * v
                        i += 3
                    }
                    level = Math.sqrt(sum / Math.max(1, k / 3)) / 32768.0
                    synchronized(buf) {
                        buf.write(out, 0, o)
                        if (buf.size() > 6_000_000) { val keep = buf.toByteArray().copyOfRange(3_000_000, buf.size()); buf.reset(); buf.write(keep) }
                    }
                }
            }.also { it.start() }
        } catch (e: Exception) {
            capturing = false
        }
    }

    private class GlowView(c: Context) : View(c) {
        var a = 0.5f
        private val p = Paint()
        override fun onDraw(cv: Canvas) {
            val w = width.toFloat(); val h = height.toFloat(); val t = 110f
            val col = ((a * 200).toInt() shl 24) or 0x2979FF
            val none = 0x002979FF
            fun edge(x0: Float, y0: Float, x1: Float, y1: Float, l: Float, tp: Float, r: Float, b: Float) {
                p.shader = LinearGradient(x0, y0, x1, y1, col, none, Shader.TileMode.CLAMP)
                cv.drawRect(l, tp, r, b, p)
            }
            edge(0f, 0f, 0f, t, 0f, 0f, w, t)
            edge(0f, h, 0f, h - t, 0f, h - t, w, h)
            edge(0f, 0f, t, 0f, 0f, 0f, t, h)
            edge(w, 0f, w - t, 0f, w - t, 0f, w, h)
        }
    }

    private fun showGlow() {
        if (glow != null) return
        if (!Settings.canDrawOverlays(this)) return
        try {
            val g = GlowView(this)
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT)
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).addView(g, lp)
            glow = g
            anim = ValueAnimator.ofFloat(0.35f, 1f).apply {
                duration = 1600; repeatMode = ValueAnimator.REVERSE; repeatCount = ValueAnimator.INFINITE
                addUpdateListener { g.a = it.animatedValue as Float; g.invalidate() }
                start()
            }
        } catch (e: Exception) { glow = null }
    }

    override fun onDestroy() {
        notesRunning = false
        capturing = false
        try { worker?.join(300) } catch (e: Exception) {}
        try { rec?.stop(); rec?.release() } catch (e: Exception) {}
        try { proj?.stop() } catch (e: Exception) {}
        anim?.cancel()
        try { glow?.let { (getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(it) } } catch (e: Exception) {}
        glow = null
        super.onDestroy()
    }
}
