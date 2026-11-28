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
import android.graphics.Canvas
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
                val b = ((Math.sin(phase * 2 * Math.PI) + 1) / 2).toFloat()
                p.style = Paint.Style.FILL
                p.color = a(if (m == "nothing") 0x8AA69E else 0x9AD4C4, 45f + 70f * b)
                cv.drawCircle(c, c, core + s * 0.05f + s * 0.05f * b, p)
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
                    p.style = Paint.Style.FILL
                    cv.drawRoundRect(c - u * 0.2f, c - u * 0.55f, c + u * 0.2f, c + u * 0.12f, u * 0.2f, u * 0.2f, p)
                    p.style = Paint.Style.STROKE; p.strokeWidth = s * 0.04f
                    cv.drawArc(RectF(c - u * 0.4f, c - u * 0.3f, c + u * 0.4f, c + u * 0.42f), 0f, 180f, false, p)
                    cv.drawLine(c, c + u * 0.42f, c, c + u * 0.62f, p)
                    if (m == "nothing") cv.drawLine(c - u * 0.45f, c - u * 0.5f, c + u * 0.45f, c + u * 0.55f, p)
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
