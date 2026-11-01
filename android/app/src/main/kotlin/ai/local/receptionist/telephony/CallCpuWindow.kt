package ai.local.receptionist.telephony

import android.content.Context
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * A 1×1 transparent, untouchable window shown only while the assistant is on
 * a call. The assistant runs with no visible UI, and some phones (Samsung)
 * then confine the app to a few efficiency cores, where speech is rendered
 * at under half real time and callers hear long gaps. A visible overlay
 * window moves the process to the full-CPU "foreground window" group.
 * Needs "Display over other apps"; without it calls work as before.
 */
object CallCpuWindow {
    private val main = Handler(Looper.getMainLooper())
    private var view: View? = null

    fun show(context: Context) = main.post {
        if (view != null) return@post
        if (!Settings.canDrawOverlays(context)) {
            Log.i("ReceptionistCall", "cpu window skipped: no overlay permission")
            return@post
        }
        val app = context.applicationContext
        val created = View(app)
        val params = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSPARENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }
        runCatching { app.getSystemService(WindowManager::class.java).addView(created, params) }
            .onSuccess { view = created; Log.i("ReceptionistCall", "cpu window shown") }
            .onFailure { Log.w("ReceptionistCall", "cpu window failed: ${it.message}") }
    }

    fun hide(context: Context) = main.post {
        val current = view ?: return@post
        view = null
        runCatching { context.applicationContext.getSystemService(WindowManager::class.java).removeView(current) }
        Log.i("ReceptionistCall", "cpu window hidden")
    }
}
