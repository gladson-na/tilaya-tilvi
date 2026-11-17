package PKG_NAME

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/** Watches for text fields in other apps and types dictated text into the focused one. */
class TildaService : AccessibilityService() {
    companion object {
        var instance: TildaService? = null
        var onFocus: ((Boolean) -> Unit)? = null
        fun insert(text: String): Boolean = instance?.doInsert(text) ?: false
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(e: AccessibilityEvent?) {
        if (e == null || e.packageName == packageName) return
        val editable = when (e.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED -> e.source?.isEditable == true
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ->
                rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.isEditable == true
            else -> return
        }
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
