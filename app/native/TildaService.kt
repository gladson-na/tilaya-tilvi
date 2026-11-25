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
import android.widget.TextView
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/** Watches for text fields in other apps and types dictated text into the focused one. */
class TildaService : AccessibilityService() {
    companion object {
        var instance: TildaService? = null
        var onFocus: ((Boolean) -> Unit)? = null
        var onTap: (() -> Unit)? = null
        var onLongPress: (() -> Unit)? = null
        fun label(t: String) { instance?.showLabel(t) }
        var auto = true
        fun insert(text: String): Boolean = instance?.doInsert(text) ?: false
        fun liveStart(): Boolean = instance?.doLiveStart() ?: false
        fun liveSet(text: String): Boolean = instance?.doLiveSet(text) ?: false
    }

    private val handler = Handler(Looper.getMainLooper())
    private var bubble: TextView? = null
    private var st = "idle"
    private var savedX = -1
    private var savedY = -1
    private var labelOverride: String? = null
    private var longFired = false
    private val lpR = Runnable { longFired = true; onLongPress?.invoke() }

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

    private fun paint(v: TextView) {
        val c = when (st) { "recording" -> Color.RED; "working" -> Color.rgb(255, 160, 0); "done" -> Color.rgb(40, 160, 70); else -> Color.rgb(0, 150, 136) }
        val g = GradientDrawable()
        g.shape = GradientDrawable.OVAL
        g.setColor(c)
        v.background = g
        v.text = labelOverride ?: when (st) { "recording" -> "■"; "working" -> "…"; "done" -> "✓"; else -> "🎙" }
    }

    private fun showBubble() {
        handler.removeCallbacks(hideR)
        bubble?.let { paint(it); return }
        try {
            val d = resources.displayMetrics.density
            val v = TextView(this)
            v.textSize = 24f
            v.setTextColor(Color.WHITE)
            v.gravity = Gravity.CENTER
            val size = (60 * d).toInt()
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
                    android.view.MotionEvent.ACTION_UP -> { handler.removeCallbacks(lpR); if (!moved && !longFired) onTap?.invoke() }
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
        bubble?.let { paint(it) }
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

    private fun doInsert(text: String): Boolean {
        val node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        if (!node.isEditable) return false
        val hint = Build.VERSION.SDK_INT >= 26 && node.isShowingHintText
        val cur = if (node.text != null && !hint) node.text.toString() else ""
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
        val hint = Build.VERSION.SDK_INT >= 26 && node.isShowingHintText
        val cur = if (node.text != null && !hint) node.text.toString() else ""
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
