package ai.local.receptionist

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    companion object {
        private const val EXTRA_CALL = "call_id"

        fun openIntent(context: Context) = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        fun callIntent(context: Context, callId: String) = openIntent(context).putExtra(EXTRA_CALL, callId)

        private const val EXTRA_PICK_UP = "pick_up"
        /** Warm transfer "Pick up": opens the app and takes the call. */
        fun pickUpIntent(context: Context, callId: String) = callIntent(context, callId).putExtra(EXTRA_PICK_UP, true)

        private const val EXTRA_THREAD = "thread_id"
        fun threadIntent(context: Context, threadId: Long) = openIntent(context).putExtra(EXTRA_THREAD, threadId)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine = EngineHolder.ensure(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ReceptionistService.start(this)
        requestBackgroundOnce()
        handle(intent)
    }

    /** Asks once for the battery-optimization exemption so calls and texts are
     *  handled while the app is closed; the Status tab can ask again. */
    private fun requestBackgroundOnce() {
        val prefs = getSharedPreferences("receptionist", MODE_PRIVATE)
        val power = getSystemService(PowerManager::class.java)
        if (power.isIgnoringBatteryOptimizations(packageName) || prefs.getBoolean("asked_background", false)) return
        prefs.edit().putBoolean("asked_background", true).apply()
        runCatching {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        EngineHolder.bridge.activity = this
        EngineHolder.bridge.emit(mapOf("type" to "ui_visible", "visible" to true))
    }

    override fun onPause() {
        EngineHolder.bridge.emit(mapOf("type" to "ui_visible", "visible" to false))
        super.onPause()
    }

    override fun onDestroy() {
        if (EngineHolder.bridge.activity === this) EngineHolder.bridge.activity = null
        super.onDestroy()
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        val callId = intent.getStringExtra(EXTRA_CALL)
        if (callId != null) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            EngineHolder.bridge.emit(mapOf("type" to "show_call", "callId" to callId))
            if (intent.getBooleanExtra(EXTRA_PICK_UP, false)) {
                EngineHolder.bridge.emit(mapOf("type" to "call_action", "action" to "pick_up", "callId" to callId))
            }
        } else {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        }
        if ((intent.action == Intent.ACTION_DIAL || intent.action == Intent.ACTION_VIEW) &&
            intent.data?.scheme == "tel") {
            EngineHolder.bridge.emit(mapOf("type" to "dial", "number" to intent.data?.schemeSpecificPart))
        }
        val thread = intent.getLongExtra(EXTRA_THREAD, -1L)
        if (thread >= 0) EngineHolder.bridge.emit(mapOf("type" to "open_thread", "threadId" to thread))
        // sms:, smsto:, mms:, mmsto: links and shared text open a conversation.
        val scheme = intent.data?.scheme
        val compose = scheme in setOf("sms", "smsto", "mms", "mmsto") ||
            (intent.action == Intent.ACTION_SEND && intent.type == "text/plain")
        if (compose && (intent.action == Intent.ACTION_SENDTO || intent.action == Intent.ACTION_SEND ||
                intent.action == Intent.ACTION_VIEW)) {
            val number = intent.data?.schemeSpecificPart?.substringBefore('?')?.replace(";", ",") ?: ""
            val body = intent.getStringExtra("sms_body") ?: intent.getStringExtra(Intent.EXTRA_TEXT)
                ?: intent.data?.getQueryParameter("body").takeIf { intent.data?.isHierarchical == true } ?: ""
            EngineHolder.bridge.emit(mapOf("type" to "compose", "number" to number, "body" to body))
        }
    }
}
