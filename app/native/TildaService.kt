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
        var auto = true
        fun insert(text: String): Boolean = instance?.doInsert(text) ?: false
    }

    private val handler = Handler(Looper.getMainLooper())
    private var bubble: TextView? = null
    private var st = "idle"
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
        v.text = when (st) { "recording" -> "■"; "working" -> "…"; "done" -> "✓"; else -> "🎙" }
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
            v.setOnClickListener { onTap?.invoke() }
            val size = (60 * d).toInt()
            val lp = WindowManager.LayoutParams(size, size, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT)
            lp.gravity = Gravity.END or Gravity.CENTER_VERTICAL
            lp.x = (12 * d).toInt()
            paint(v)
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).addView(v, lp)
            bubble = v
        } catch (_: Exception) {}
    }

    private fun hideBubble() {
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
        else if (st == "idle") { handler.removeCallbacks(hideR); handler.postDelayed(hideR, 2500) }
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
}
