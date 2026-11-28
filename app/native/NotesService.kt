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
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
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
        /** Told to the app: "pause", "resume", "stop" or "cancel". Null when the app screen is gone. */
        @Volatile var onControl: ((String) -> Unit)? = null
        @Volatile var instance: NotesService? = null
        /** The app changed pause by itself (its own button): keep the floating strip in step. */
        fun syncPaused(p: Boolean) { instance?.let { s -> Handler(Looper.getMainLooper()).post { s.paintPaused(p) } } }
        fun take(): ByteArray = synchronized(buf) { val b = buf.toByteArray(); buf.reset(); b }
    }

    private var proj: MediaProjection? = null
    private var rec: AudioRecord? = null
    private var worker: Thread? = null
    private var glow: GlowView? = null
    private var anim: ValueAnimator? = null
    private var bar: LinearLayout? = null
    private var barLp: WindowManager.LayoutParams? = null
    private var pauseBtn: View? = null
    private var playBtn: View? = null
    private var cancelBtn: View? = null
    private var clock: TextView? = null
    private var paused = false
    private var runStart = 0L
    private var elapsedMs = 0L
    private val ui = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            if (!paused) {
                val sec = ((elapsedMs + System.currentTimeMillis() - runStart) / 1000).toInt()
                clock?.text = String.format("%02d:%02d", sec / 60, sec % 60)
            }
            ui.postDelayed(this, 1000)
        }
    }

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
        instance = this
        if (!micOnly) { showGlow(); showControls() }
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
            val col = ((a * 200).toInt() shl 24) or 0x2FB59A
            val none = 0x002FB59A
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


    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    /** A round button with a drawn icon: 0 close, 1 pause, 2 play, 3 stop. */
    private inner class IconBtn(c: Context, val kind: Int, val fill: Int) : View(c) {
        private val p = Paint(Paint.ANTI_ALIAS_FLAG)
        init {
            minimumWidth = dp(38); minimumHeight = dp(38)
            contentDescription = when (kind) { 0 -> "Cancel"; 1 -> "Pause"; 2 -> "Resume"; else -> "Stop" }
        }
        override fun onMeasure(w: Int, h: Int) = setMeasuredDimension(dp(38), dp(38))
        override fun onDraw(cv: Canvas) {
            val s = width.toFloat(); val c = s / 2
            p.style = Paint.Style.FILL; p.color = fill
            cv.drawCircle(c, c, c, p)
            p.color = Color.WHITE
            when (kind) {
                0 -> { p.style = Paint.Style.STROKE; p.strokeWidth = s * 0.09f; p.strokeCap = Paint.Cap.ROUND
                    val d = s * 0.27f
                    cv.drawLine(c - d, c - d, c + d, c + d, p); cv.drawLine(c + d, c - d, c - d, c + d, p) }
                1 -> { val w = s * 0.11f; val h = s * 0.28f
                    cv.drawRoundRect(c - w * 1.9f, c - h, c - w * 0.5f, c + h, 3f, 3f, p)
                    cv.drawRoundRect(c + w * 0.5f, c - h, c + w * 1.9f, c + h, 3f, 3f, p) }
                2 -> { val path = android.graphics.Path(); val h = s * 0.28f
                    path.moveTo(c - h * 0.7f, c - h); path.lineTo(c + h, c); path.lineTo(c - h * 0.7f, c + h); path.close()
                    cv.drawPath(path, p) }
                else -> { val h = s * 0.24f; cv.drawRoundRect(c - h, c - h, c + h, c + h, 5f, 5f, p) }
            }
        }
    }

    private fun refreshButtons() {
        pauseBtn?.alpha = if (paused) 0.3f else 1f
        playBtn?.alpha = if (paused) 1f else 0.3f
    }

    private fun paintPaused(p: Boolean) {
        if (p == paused) return
        val now = System.currentTimeMillis()
        if (p) elapsedMs += now - runStart else runStart = now
        paused = p
        refreshButtons()
        if (p) clock?.text = "Paused"
    }

    private var cancelArmed = false

    private fun send(what: String) {
        val cb = onControl
        if (cb != null) { try { cb(what) } catch (e: Exception) {} }
        else {
            // the app screen is gone: Stop and Cancel just end the recording, and Stop reopens the app
            if (what == "stop" || what == "cancel") {
                if (what == "stop") packageManager.getLaunchIntentForPackage(packageName)?.let { startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                stopSelf()
            }
        }
    }

    private fun showControls() {
        if (bar != null) return
        if (!Settings.canDrawOverlays(this)) return
        try {
            val teal = 0xFF0B6B5A.toInt()
            val bg = GradientDrawable().apply { setColor(0xEE0E1A17.toInt()); cornerRadius = dp(24).toFloat() }
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = bg
                setPadding(dp(8), dp(5), dp(8), dp(5))
            }
            val handle = TextView(this).apply {
                text = "::"; setTextColor(0xFF8FB8AC.toInt()); textSize = 18f
                setPadding(dp(4), 0, dp(8), 0)
                contentDescription = "Drag"
            }
            clock = TextView(this).apply { text = "00:00"; setTextColor(Color.WHITE); textSize = 14f; setPadding(0, 0, dp(8), 0) }
            cancelBtn = IconBtn(this, 0, 0xFF8A2B25.toInt()).apply {
                setOnClickListener {
                    if (!cancelArmed) {
                        cancelArmed = true
                        clock?.text = "Tap X again"
                        ui.postDelayed({ cancelArmed = false; if (paused) clock?.text = "Paused" }, 3000)
                    } else {
                        cancelArmed = false
                        send("cancel")
                    }
                }
            }
            pauseBtn = IconBtn(this, 1, teal).apply { setOnClickListener { if (!paused) { paintPaused(true); send("pause") } } }
            playBtn = IconBtn(this, 2, teal).apply { setOnClickListener { if (paused) { paintPaused(false); send("resume") } } }
            val stop = IconBtn(this, 3, 0xFF2D7D6E.toInt()).apply { setOnClickListener { send("stop") } }
            refreshButtons()
            row.addView(handle); row.addView(clock)
            for (b in listOf(cancelBtn!!, pauseBtn!!, playBtn!!, stop)) row.addView(b, LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(5) })
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT)
            lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            lp.y = dp(70)
            // drag by the handle
            var sy = 0f; var sx = 0f; var oy = 0; var ox = 0
            handle.setOnTouchListener { _, e ->
                when (e.action) {
                    MotionEvent.ACTION_DOWN -> { sx = e.rawX; sy = e.rawY; ox = lp.x; oy = lp.y; true }
                    MotionEvent.ACTION_MOVE -> {
                        lp.x = ox + (e.rawX - sx).toInt(); lp.y = oy + (e.rawY - sy).toInt()
                        try { (getSystemService(Context.WINDOW_SERVICE) as WindowManager).updateViewLayout(row, lp) } catch (x: Exception) {}
                        true
                    }
                    else -> true
                }
            }
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).addView(row, lp)
            bar = row; barLp = lp
            runStart = System.currentTimeMillis(); elapsedMs = 0L
            ui.post(tick)
        } catch (e: Exception) { bar = null }
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
        instance = null
        ui.removeCallbacksAndMessages(null)
        try { bar?.let { (getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(it) } } catch (e: Exception) {}
        bar = null
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
