package PKG_NAME

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.util.Base64
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.view.View
import android.view.animation.LinearInterpolator
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/** Watches for text fields in other apps and types dictated text into the focused one. */
class TildaService : AccessibilityService() {
    companion object {
        var instance: TildaService? = null
        var onFocus: ((Boolean) -> Unit)? = null
        var onTap: (() -> Unit)? = null
        var onLongPress: (() -> Unit)? = null
        fun saveLang(c: Context, l: String) { try { c.getSharedPreferences("tilda_native", Context.MODE_PRIVATE).edit().putString("lang", l).apply() } catch (_: Exception) {} }
        fun label(t: String) { instance?.showLabel(t) }
        var auto = true
        fun insert(text: String): Boolean = instance?.doInsert(text) ?: false
        fun liveStart(): Boolean = instance?.doLiveStart() ?: false
        fun liveSet(text: String): Boolean = instance?.doLiveSet(text) ?: false
    }

    private val handler = Handler(Looper.getMainLooper())
    private var bubble: BubbleView? = null
    private var st = "idle"
    private var savedX = -1
    private var savedY = -1
    private var labelOverride: String? = null
    private var longFired = false
    private val lpR = Runnable { longFired = true; onLongPress?.invoke() }

    /** One tap on the bubble: always answers something, even when the app screen is gone. */
    private fun tapped() {
        val cb = onTap
        if (cb == null) {
            // the app screen is gone: the bubble listens by itself and types into the box, Tilda never opens
            nativeToggle()
            return
        }
        showLabel("…")
        startMic()
        try { cb() } catch (_: Exception) { showLabel("!"); stopMic() }
    }

    private var rec: SpeechRecognizer? = null

    private fun piece(t: String): String = if (liveBase.isNotEmpty() && !liveBase.endsWith(" ") && !liveBase.endsWith("\n")) " $t" else t

    private fun endNative() { try { rec?.destroy() } catch (_: Exception) {}; rec = null }

    /** With the app screen gone: the phone's own speech engine listens and the words go straight into the box. Tap again to stop. */
    private fun nativeToggle() {
        if (rec != null) {
            try { rec?.stopListening() } catch (_: Exception) {}
            setState("working")
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(this) || !doLiveStart()) { setState("nothing"); return }
        startMic()
        setState("working")
        val lang = try { getSharedPreferences("tilda_native", Context.MODE_PRIVATE).getString("lang", "en-IN") ?: "en-IN" } catch (_: Exception) { "en-IN" }
        handler.postDelayed({
            try {
                val r = SpeechRecognizer.createSpeechRecognizer(this)
                rec = r
                r.setRecognitionListener(object : RecognitionListener {
                    private fun best(b: Bundle?): String? = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }
                    override fun onReadyForSpeech(p: Bundle?) { setState("recording") }
                    override fun onPartialResults(b: Bundle?) { best(b)?.let { doLiveSet(piece(it)) } }
                    override fun onResults(b: Bundle?) {
                        val t = best(b)
                        if (t != null) { doLiveSet(piece(t)); setState("done") } else setState("nothing")
                        endNative()
                    }
                    override fun onError(e: Int) {
                        setState(if (e == SpeechRecognizer.ERROR_NO_MATCH || e == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) "nothing" else "idle")
                        endNative()
                    }
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(v: Float) {}
                    override fun onBufferReceived(b: ByteArray?) {}
                    override fun onEndOfSpeech() { if (st == "recording") setState("working") }
                    override fun onEvent(t: Int, b: Bundle?) {}
                })
                r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
                    .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName))
            } catch (_: Exception) { endNative(); setState("nothing") }
        }, 250)
    }

    /** Keeps the microphone allowed while another app is on screen (Android blocks it otherwise). */
    private fun startMic() {
        try {
            val i = Intent(this, NotesService::class.java).putExtra("micOnly", true)
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
        } catch (_: Exception) {}
    }

    private fun stopMic() {
        try { if (!NotesService.notesRunning) stopService(Intent(this, NotesService::class.java)) } catch (_: Exception) {}
    }

    private fun showLabel(t: String) {
        labelOverride = t
        bubble?.let { paint(it) }
        handler.postDelayed({ labelOverride = null; bubble?.let { paint(it) } }, 1800)
    }

    private fun screenW(): Int = try {
        if (Build.VERSION.SDK_INT >= 30) (getSystemService(Context.WINDOW_SERVICE) as WindowManager).currentWindowMetrics.bounds.width()
        else resources.displayMetrics.widthPixels
    } catch (_: Exception) { resources.displayMetrics.widthPixels }

    private fun screenH(): Int = try {
        if (Build.VERSION.SDK_INT >= 30) (getSystemService(Context.WINDOW_SERVICE) as WindowManager).currentWindowMetrics.bounds.height()
        else resources.displayMetrics.heightPixels
    } catch (_: Exception) { resources.displayMetrics.heightPixels }
    private val watchR = object : Runnable {
        override fun run() {
            if (bubble != null) {
                if (st != "recording" && !keyboardUp()) { hideBubble(); return }
                handler.postDelayed(this, 700)
            }
        }
    }
    private var onField = false
    private val hideR = Runnable { hideBubble() }

    override fun onServiceConnected() {
        instance = this
    }

    private fun paint(v: BubbleView) {
        v.mode = st
        v.label = labelOverride
        v.invalidate()
    }

    /** The bubble, drawn in the app's colours: a soft glow when idle, rings while listening, a turning arc while working. */
    private inner class BubbleView(c: Context) : View(c) {
        var mode = "idle"
        var label: String? = null
        private val p = Paint(Paint.ANTI_ALIAS_FLAG)
        private var phase = 0f
        private var doneAt = 0L
        private var lastMode = ""
        private val logoPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        /** The Tilda mark, white on clear, drawn in place of a microphone. */
        private val logo: Bitmap? by lazy {
            try {
                val raw = Base64.decode(LOGO_B64, Base64.DEFAULT)
                BitmapFactory.decodeByteArray(raw, 0, raw.size)
            } catch (_: Exception) { null }
        }
        private val anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1700
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { phase = it.animatedValue as Float; invalidate() }
        }

        override fun onAttachedToWindow() { super.onAttachedToWindow(); anim.start() }
        override fun onDetachedFromWindow() { anim.cancel(); super.onDetachedFromWindow() }

        private fun a(rgb: Int, alpha: Float) = (rgb and 0xFFFFFF) or ((alpha.coerceIn(0f, 255f)).toInt() shl 24)

        override fun onDraw(cv: Canvas) {
            val s = width.toFloat(); val c = s / 2
            val m = if (label == "…") "working" else mode
            if (m != lastMode) { lastMode = m; if (m == "done") doneAt = System.currentTimeMillis() }
            val pop = if (m == "done") (1f + 0.22f * Math.max(0f, 1f - (System.currentTimeMillis() - doneAt) / 260f)) else 1f
            val core = s * 0.33f * pop
            val hi: Int; val lo: Int
            when (m) {
                "recording" -> { hi = 0xFFE0675D.toInt(); lo = 0xFFB3261E.toInt() }
                "nothing" -> { hi = 0xFF8AA69E.toInt(); lo = 0xFF55716A.toInt() }
                "done" -> { hi = 0xFF3DB48C.toInt(); lo = 0xFF0B6B5A.toInt() }
                else -> { hi = 0xFF2D9C86.toInt(); lo = 0xFF0B6B5A.toInt() }
            }
            // halo
            p.shader = null
            if (m == "recording") {
                for (k in 0..1) {
                    val t = (phase + k * 0.5f) % 1f
                    p.style = Paint.Style.STROKE; p.strokeWidth = s * 0.035f
                    p.color = a(0xB3261E, (1f - t) * 170f)
                    cv.drawCircle(c, c, core + (c - core - s * 0.02f) * t, p)
                }
            } else {
                // idle is completely still, so it never looks like it is recording
                p.style = Paint.Style.FILL
                p.color = a(if (m == "nothing") 0x8AA69E else 0x9AD4C4, 55f)
                cv.drawCircle(c, c, core + s * 0.06f, p)
            }
            // soft shadow, then the core with a light from the top left
            p.style = Paint.Style.FILL; p.color = 0x30000000
            cv.drawCircle(c, c + s * 0.025f, core, p)
            p.shader = RadialGradient(c - core * 0.4f, c - core * 0.45f, core * 1.7f, hi, lo, Shader.TileMode.CLAMP)
            cv.drawCircle(c, c, core, p)
            p.shader = null
            p.style = Paint.Style.STROKE; p.strokeWidth = s * 0.012f; p.color = a(0xFFFFFF, 90f)
            cv.drawCircle(c, c, core - s * 0.006f, p)
            // icon, all in white
            p.color = Color.WHITE
            p.strokeCap = Paint.Cap.ROUND; p.strokeJoin = Paint.Join.ROUND
            val u = core
            when {
                label != null && label != "…" -> {
                    p.style = Paint.Style.FILL; p.textAlign = Paint.Align.CENTER; p.textSize = s * 0.2f; p.isFakeBoldText = true
                    cv.drawText(label!!, c, c + p.textSize * 0.35f, p); p.isFakeBoldText = false
                }
                m == "recording" -> { p.style = Paint.Style.FILL; cv.drawRoundRect(c - u * 0.3f, c - u * 0.3f, c + u * 0.3f, c + u * 0.3f, u * 0.12f, u * 0.12f, p) }
                m == "working" -> {
                    p.style = Paint.Style.STROKE; p.strokeWidth = s * 0.05f
                    cv.drawArc(RectF(c - u * 0.45f, c - u * 0.45f, c + u * 0.45f, c + u * 0.45f), phase * 360f, 250f, false, p)
                }
                m == "done" -> {
                    p.style = Paint.Style.STROKE; p.strokeWidth = s * 0.055f
                    val t = Path(); t.moveTo(c - u * 0.38f, c + u * 0.02f); t.lineTo(c - u * 0.1f, c + u * 0.3f); t.lineTo(c + u * 0.4f, c - u * 0.26f)
                    cv.drawPath(t, p)
                }
                else -> {
                    val lg = logo
                    if (lg != null) {
                        val h = u * 1.25f
                        logoPaint.colorFilter = PorterDuffColorFilter(Color.WHITE, PorterDuff.Mode.SRC_IN)
                        cv.drawBitmap(lg, null, RectF(c - h / 2, c - h / 2, c + h / 2, c + h / 2), logoPaint)
                    }
                    if (m == "nothing") { p.style = Paint.Style.STROKE; p.strokeWidth = s * 0.04f; cv.drawLine(c - u * 0.5f, c - u * 0.5f, c + u * 0.5f, c + u * 0.55f, p) }
                }
            }
        }
    }

    private fun showBubble() {
        handler.removeCallbacks(hideR)
        bubble?.let { paint(it); return }
        try {
            val d = resources.displayMetrics.density
            val v = BubbleView(this)
            val size = (64 * d).toInt()
            val lp = WindowManager.LayoutParams(size, size, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT)
            lp.gravity = Gravity.TOP or Gravity.START
            val dm = resources.displayMetrics
            lp.x = (if (savedX >= 0) savedX else dm.widthPixels - size - (12 * d).toInt()).coerceIn(0, Math.max(0, screenW() - size))
            lp.y = (if (savedY >= 0) savedY else dm.heightPixels / 2 - size).coerceIn(0, Math.max(0, screenH() - size))
            var downX = 0f; var downY = 0f; var startX = 0; var startY = 0; var moved = false
            v.setOnTouchListener { _, ev ->
                val wm2 = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                when (ev.action) {
                    android.view.MotionEvent.ACTION_DOWN -> { downX = ev.rawX; downY = ev.rawY; startX = lp.x; startY = lp.y; moved = false; longFired = false; handler.postDelayed(lpR, 600) }
                    android.view.MotionEvent.ACTION_MOVE -> {
                        val dx = ev.rawX - downX; val dy = ev.rawY - downY
                        if (moved || Math.abs(dx) > 12 * d || Math.abs(dy) > 12 * d) {
                            moved = true
                            handler.removeCallbacks(lpR)
                            lp.x = (startX + dx).toInt().coerceIn(0, Math.max(0, screenW() - size))
                            lp.y = (startY + dy).toInt().coerceIn(0, Math.max(0, screenH() - size))
                            savedX = lp.x; savedY = lp.y
                            try { wm2.updateViewLayout(v, lp) } catch (_: Exception) {}
                        }
                    }
                    android.view.MotionEvent.ACTION_UP -> { handler.removeCallbacks(lpR); if (!moved && !longFired) tapped() }
                }
                true
            }
            paint(v)
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).addView(v, lp)
            bubble = v
            handler.removeCallbacks(watchR)
            handler.postDelayed(watchR, 1500)
        } catch (_: Exception) {}
    }

    private fun hideBubble() {
        handler.removeCallbacks(hideR)
        handler.removeCallbacks(watchR)
        bubble?.let { try { (getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(it) } catch (_: Exception) {} }
        bubble = null
    }

    fun setState(s: String) {
        st = s
        if (s == "idle" || s == "done" || s == "nothing") handler.postDelayed({ if (st != "recording" && st != "working") stopMic() }, 2500)
        bubble?.let { paint(it) }
        if (s == "nothing") handler.postDelayed({ if (st == "nothing") setState("idle") }, 2500)
        if (s == "idle" && !onField) handler.postDelayed(hideR, 2500)
    }

    private fun keyboardUp(): Boolean =
        try { windows.any { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD } } catch (_: Exception) { true }

    private fun focusChanged(editable: Boolean) {
        onField = editable
        if (!auto) { hideBubble(); return }
        if (editable && keyboardUp()) showBubble()
        else if (st != "recording") { handler.removeCallbacks(hideR); handler.postDelayed(hideR, 1200) }
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        hideBubble()
        return super.onUnbind(intent)
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(e: AccessibilityEvent?) {
        if (e == null || e.packageName == packageName) return
        if (e.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
            if (onField && !keyboardUp()) focusChanged(false)
            else if (onField) focusChanged(true)
            return
        }
        val editable = when (e.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED -> e.source?.isEditable == true
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ->
                rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.isEditable == true
            else -> return
        }
        focusChanged(editable)
        onFocus?.invoke(editable)
    }

    /** What the person really typed. Some apps (WhatsApp) show the placeholder "Message" as if it were text. */
    private fun realText(node: AccessibilityNodeInfo): String {
        val t = node.text?.toString() ?: return ""
        if (Build.VERSION.SDK_INT >= 26) {
            if (node.isShowingHintText) return ""
            val h = node.hintText?.toString()
            if (!h.isNullOrEmpty() && h == t) return ""
        }
        if (t.trim().lowercase() in placeholders) return ""
        return t
    }

    private val placeholders = setOf("message", "type a message", "write a message", "type a message...", "message...", "search", "add a comment...")

    private fun doInsert(text: String): Boolean {
        val node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        if (!node.isEditable) return false
        val cur = realText(node)
        val s = node.textSelectionStart.coerceIn(0, cur.length)
        val e = node.textSelectionEnd.coerceIn(s, cur.length)
        val out = cur.substring(0, s) + text + cur.substring(e)
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, out)
        if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
            val pos = s + text.length
            val sel = Bundle()
            sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, pos)
            sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, pos)
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
            return true
        }
        // some fields refuse SET_TEXT: paste instead
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("tilda", text))
        return node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
    }

    private var liveBase = ""
    private var liveTail = ""

    /** Remembers where the cursor is, so live words can replace the same spot again and again. */
    private fun doLiveStart(): Boolean {
        val node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        if (!node.isEditable) return false
        val cur = realText(node)
        val s = node.textSelectionStart.coerceIn(0, cur.length)
        val e = node.textSelectionEnd.coerceIn(s, cur.length)
        liveBase = cur.substring(0, s)
        liveTail = cur.substring(e)
        return true
    }

    private fun doLiveSet(text: String): Boolean {
        val node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        if (!node.isEditable) return false
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, liveBase + text + liveTail)
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return false
        val pos = liveBase.length + text.length
        val sel = Bundle()
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, pos)
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, pos)
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
        return true
    }
}

private const val LOGO_B64 =
            "iVBORw0KGgoAAAANSUhEUgAAAKAAAACgCAYAAACLz2ctAAASG0lEQVR42u2de7QddXXHPzPnJCQ0BJAAhYTyDEGLFUvAREKh1ZbSWkUtoLIKtj666OpatC5rH2tRtWit8geUumiBFmrq0jb4itZWEZFHQAIUWsWUEBqXCgXjKyE8Ajlnpn/s/evdTOacnHPvzJyZOXuvdda9ubn3nJn5fX/7tx/fvXeUpikuLpOS2B+BiwPQxQHo4uIAdHEAurg4AF0cgC4uDkAXB6CLiwPQxQHo4uIAdHEAurgUKd0aXlOUeWUlzfn9vN+xLxcH4FDAxfo10VdasJYPmj5xUNZM20yIDxhAEQBnZT5wOHCEvpYBBwOLgUXAQrNx+sAzwE5gB/B94HHgUX09DuzK+fxOBpAuUwDASBe+n1n0w4CTgNXAKcAKBeA+c/y85xWAW4H/Au4F7ge26DU4GKcEgOF4tYv+EuA1wNnAy4H9c/5u0HEZjWATRgMcrD6wGdgA3ATcBvwwY5LkaWWXBgIwgCAA7yDgHOAC4PSM/RkWfW8OyDiSdUQio+2C/AC4GfiUfn1yyKZxaQgAw0L39N/HAO8ELtTjNkgv44BUIQGMSQ4gvwesA/4ReHDAJnKpOQA7ZrGWAe8BfludB8z/VQm6vQEyydiCPeDfgKuBLzsQmwFAq/XmA5co+JaYRe3UBHTDwNjPmAa3ApcrIANIU7cR6wXA2CzImcAV6tU2BXiDtKJ1ZL4KXKZOS3BW+u41Tx6AXQVZF/igar2mAo8BXrMF4ieA9wKP5Gw+l4oBGMC3AvgH4DRj5Lctx9w3duuTqg2vNJuv51CqDoDWID8HuB440CxGm6VvnJWNwB8Ad5uwkWvDktkwFnzvBj6r4OtPAfisE9IDXgHcAVxqjuKuQ6o8DWh3+eUKwGSKaV32WL4DiXU+5A5KOQC04LsOeHuLHI2iQjc7gN8HPu4OSrFHcGQe5vUKvt360KNp38BG4+0P/BPw" +
            "N0gsNMlJ/bmMqQFtgPlq4GIF3zx/dAPjhx3gTuDNSHrPveQ5aMAAvvc6+MbKBp0G3AWcMSXRgVI0YNi5FwIfc5tvVuGa3WoXXqub3dnYIwIwkApWIty5bo0IBE0RSy+7nJksUcdJDcMBGB7aYoRBfLQ+TK+gm5td+FngrUgmxUE4xAbs6EO7WsHXc/AVYhe+HmHXHD1FgfuxARge1pvUi3MDmsKqD3tI+cEGYI0/2z2P4HD0HgR8S79WleVI2ZNGv7eaYRpokwbn5Dkkc7LWnDhpC5VbbO4tyquE7Gb+oA/8JVIGWeYOHUSNj2axoOkEqP3MIZecIBV/HwOWI7nkNmVOokyN9yD2ed9qwPCDl6njAcUUBg0CTDcHkN8HHkOq1J4Ans3c1CKkpuRApGzzkJzrS4zDFDfEOVkHvA14qgVBa+tc/Tzwm0ip7X5I/fZdwA3A/4TfDQAMu+8LSLlkkdovNaCIDBC/gTCMNwCbkELynSO+535IzckJwMnAKrWvXpSTp61z7DI85wfU5t7cYBCG614KfFjvJ08J7ERobNcDnShNUxvzu6dAQmmakw/9uu74r6idyRg1vele6jEO1t12NnCWHm+DmM11BOGPgIuAL2ZaiTQJfK8E/kWVQ2qeuz2hQibtHGC9BeAn1fstQvtZ4uYuvajrkBxp9sJn00goWz+ctTf20YfxFuC1elzbqrxOjYmuf4GkPmmINgzXeBYS61y4FwwFGtt3gRPDEbxM1f/COXqXVuv1Ear+FQhPzsbFyug+YB0Ru2hLgPPU63yZ2YlxDe3CcPp8GWEdPVpzLzmA7wzgS8CCzGZiSJYoBi4Ii3A+sG+OypxNAU8HuAXp9fK7Cr6OyYX2SjpagsrvmevoqFNztZoY56rdGdfUe4yNNrlXjfjguHVqCr6TgPUKvlEpaGGzvTZowDsQBsdsOWxB5e4E/gz4aI3qaLOdGlBHay1wQE3jiVaLXIvkkXfUqC45gO8EJLtz6Jin" +
            "SgidPRilaXqseqT7mv+YDfjuQbogbKqpEZ3tzrUZOL7GeW57JD+sIFxfg7rkeQjL5yVqKiwb8djNA+C3Y+AXFHzJmOCzdPS1agdsqnGHqdQs2oE11n55R/LxwOeAfwaO1Z+lFbPSA/t7t5ozt8wSfGTTJacMaHM2yu7sIJH8i9Tb7dTcawuLtb8BYBNCHGFDnw/8B/B+da4sEOOSA8zhtHsD0kns0LmCD3g+1t01jiawgeV3AB8wO7HfgDQRSCZl/ixNDiaYVw21J3+ONN38IyT43jNrUmTgPTZmSxf4EPBpvYa51LyE0/E7sS7GqAC0YZa3AX+vNkGvIcn0cI/HZuKCNLAu+XDgI8A3kfz9cl0b6zWPSyQOx37XxFf7al7dCfyJCQkVoXHvjxmvFW5QuRcjqZRgkDZNToDGV+IFm/Zw4E9VI34GiXkeZEJSFjDdIS/rYQeFskrtzlvVVOsVRPoI4L25O4YWCN7upcDfGYOUhjGUAU5sKJ0rz6sPQFyIkF5fD2xTjXUTkmt/RG30ZARgLAdejcQgz8zY/N2C1iBCKgY3dhEWyvK92EMBfNcYm6/XwAXrq9b+2RYAME8jBoAdYsCYAt9BmrVvRRhH28z0gJ9CphEco6GV4zO2XdGEjvB+NwFPRWmaXoVUbg0yKgP4bgVeZWyDtIEEyUQf9EMKxCKckLqm9ZI55L17A3pqU1CxVqx25e2xejWDFiF0QNiCpLGaPH0o3OOLFXxJQbs6rmEvGJuKTI0z0dvLKzFHbafEfov3Itm3OAZuR1rQBqq4vdB5SEL815GcapNZuwFsKwvM0uxEgu+dGoehIhNO6e7lVQWrPEKamaYBgGhI5X71iO2F3qmG6JYWlBIGwL2iAPsvvNcO9RTfx0zhfg8vPh9m+20APh+yPFGappE+sH0ViGuApxF6zY3GhU8abqinanBvQaj9c7Hdwt8+pIZ7qsC+UgFJAVkCWlgfHU6g/8xS8qMhu7YNxTJBe58M" +
            "3FeA8xHAdZ/Gx0I8tINkJy7VDe3tTF7oyH5An83/n6ZxJjbTNUdwp0VtZ6PM8dsv8MFiArR94K8QLuRtDUpRln30dpGCpPcbgu0eNb8hxdM3X9tiy4T7OL3g991hAJ4Y8sA31Ha+BPhJiSzwJtjdHSTW/CZjH6fTNjE9BKBXFnTf4QH+MMehsemqq/QzbzSEgmlxUkKY6zngjUjmo5PdhNMAwHCPy5G+LEWOkXh2gEdt42lbkfzsuUhKbBqO5cScCudpNCU37TtNAFxTQihp1wg2YtB8n0KKtS9DirTbeiyHqrfdqvk+Pyx1G09JCACTWC9Sto+oDYIttBPh8p2M1Edbnl/SEm+3g9Q4n42UEAzlDcRT0B6tj5BPTy3hnrfPIg3VReKH5wO/rN5hp+FATIy3+4A6e7eMQlqZBgCCMDyOLoEB/cwstHHPpMZuRqoRz0Niih0Td+035HSx9/O3Cr7/HrU8o+0AjE38L55j3fMgrTYXjRFirTfqNV6A1HzEmTqMtKbACxr9YeB1wO8hWbSRZytPSxjmtJI0686CuoUFh+QTaiqcw8ywbOs1Tzo2m2RMie1IK5GV6myMnbzoTkkKaFXBGy4A8MlZVBQO06TBS1+vr5XIlII3IF2nsr9fdsMl2xDKVt5tQ0pxP4qQXWfdfL2oiel1JqAuZ6ZeuSgbMJARzkRSbkWGdyLTxiRokgOQbg7n6WfuNyAlGM+he2y2SVQeIfUeZBrUOgUhc+1d0225/ZeoFumWxE55vsQCeluOuR2ZQfdxpBj8lzTM8UrgZwasY8Jo5OFoSIfZXUix05f0iL2fPSv0+nMtem67rC7omJyUzZVktOKjevytRRg3L1a78RTgpcCRSFXcuEfzbiRnu0VBdw8yE3lrDmb6RWn8Nh/BgWK2UReoSA0YjqhV+v5VknVjA8a8zzwA+GnVlIfp9/P12N5H/+4Z9VafZqZI6VEF4DMD6P2lZG26LQffwczUAMcleMHPT0C7" +
            "WiBkO8r29bjezkxPxtkC3H5Wr8y+I221//pI/e/igivXUgPw56hHB61kSPfYcUdkVJqf7rY8A3JqiaWTvRoAcBgoWzOwmgYTEE6lvAL0XkPbkjgAKyIgdCm3A0JiAOhVcA7APY7fpcBRJQPQJ6E7AAcCcIWGHZISAZg4hByAgwD40oYNe3EAtkxW+PI6AJlgC47jSm7BFvkgbwdgHigSJPV0VMkA7PjAaQfgIFmCdHEvG4DzWtTo0gFY4P0sZfaDdxgjizTfIeQAzPOAjyjRA44MABc4hByAebK05AxFeN99/Qh2AObJEVSTa/b+fw7AXDm0os/Z3yHkACQnBnhIyUdj+JzD/Ah2AOYdjVUNInyRQ8gBmKXhR8yULZatmY5yCDkAszIfWFRxuMf5gA7AFwBwQQV5YJASyMgZNw7A7D11K9KARyLT11N3RByAmNhcXJG9eSAzs4edGeMApOpWtAAneSjGAUhOTxQa2vrNAdgCAPYrfHarB3WAd5lOAPaopmVG6M9yHNIgKHWTxgEI0q3g6YpHEpzlNrUDMDVF6TsqChAHx+Mt4/RFdmk/IfUHVBfySYCXI/35nKLllHwA/rfCFFnIgrzdU3IOwCDfpdrAd4pMg1xaUicuB2DD5OEKg8PB7lwE/LGn5ZwPCNLnuMr7C7bgO5CwjGvBKWdEP6KOSFSRXRY+ZwFwhccEp1sDxsgAmQcrbk4UGpW/BvgdZobkuEwhHQtkCmXV7WrDbJK/Rpoj9TwsM30ADIC7bQINhMJRvAgZUL3YZEtcpqw71kZk/kVcMWO5Yzr0f46ZJpmdCjdBaJzUyXzvAKxIA3bUDvxizhiDqkDYA34R+IJqxH7JNmFk5uH19fP7me9rt95tnZQUtNCvIGNPJxUWCY7IvUigeqv+u8j2vrGJRaLvvxoZang80sFrM/DvwN0OwGpzwvOBbwHHTDA0EkaEbQMuBj5jgDJbIGanI4FMhboIeCsz0wGyci0yVDqtyzyR" +
            "Ns8J6SDUrGsnXLkWtPEhwKeBG3RD9Ixm7g6YVpkFXCdzzPaRmpSPIGGnyxV8YaJ5zxzBPeCdwAfrFChv+7DCoBk2M9PHJZrwBKMQp7wGuI6ZrE0WbNGAUVzosboG+C3gXFMH3R/i+admYsAKJFgfT7qktM0ADMdcD/gw8J6aBIft1M5nga8is3jvBL6tP8vToocjBVCvVtv2hIyt2Rlhc4X7/0PgSvN8HIAVaMGHVAuOOsSvbG2YDc0kwPd44djUBUinr0ORLgwLc94jHuN+AlCvR+hjEwdg21NFqd7jNuBDaivVQQtGhsaVGC13pL6Gac/UjFTtzOJzI2SGMO6EVFu3cSXwzZpVsEUmWJyair5exolIjGPVncO6BcA9iQeiK68V2a1eYEI9R5pmPd2uyWDEBZoNqRlmHTkAqzX87wYum+I63gDku+pyBLfdCcnTMAnwFeBVU0aZCiGYJ5AMyVMV8iW9N0zm2H0zM2mx/pQB8BoFX9c1IBPNTJwI3IG08207hT542j9C4oc/cS948vbgg8BvIPG2uOVNJkMk4N3Aj01bEfeCJ7ggXWADQqHf2eLOBruR1N0NwFpzAjgbhvqk6lYj6bAlLXNMAvi+BvxqJqbocUDq0UmrC3wdOAPYZECZtgR8G4DXIR3Dkrrdl9cqzORHNwGnI3y9bobk2cT+iPMQRvivGRMjdUp+vY30HwNvBN6lGqPTMG3YM9mUKzL2bS2drGm3AQcl6xNgpS7imjEpT5MMs8RIoPkSYJ251tSr4mhMsDrRI/g+tQsvQdg04Viuk0bsG+0dA5/UjbPOEBxqrWFcA+69BW+KDCV8F0JmWDwC+7iKTWIJCncB70NSjNQt1OIApJDMCcDRSFHPhcxM5LS2V1lk1yxvMMjtwFVIrYltktSYRXUAjkdk6Jt5xOcDFwCnDiCNWu0YzSJnnWbIp0G2A/+KsJq/NmCj4ABsN53JLvQpSJztbODnBgSx+yNopWgI728bUjOy" +
            "HrgJeHzAxsABOD0asZNTT7FCNeIqpG/0cUg9yjiyC3gMIY1uRALJD6jmI3MMNz516AAsRivGA4p7DkCKiZapI7NEf7bQZCueQuKPTyjwHlMNt3vA5/Tb1IvaAVgOGCkAKLHxxJO2NkB3AFYT2B7FO05znBCmgQ3iQiUsbBfPhLg4AF1cHIAuDkAXFwegiwPQxQHo4uIAdHEAurg4AF0cgC4uDkAXB6CLS9nyfy+JjvmsBAI6AAAAAElFTkSuQmCC"
