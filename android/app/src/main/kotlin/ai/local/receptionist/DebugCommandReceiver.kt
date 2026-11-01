package ai.local.receptionist

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Debug builds only (registered in src/debug/AndroidManifest.xml, restricted
 * to the adb shell): forwards test commands to the Dart runtime, e.g.
 *   adb shell am broadcast -a ai.local.receptionist.DEBUG --es command sms \
 *       --es number +15555550123 --es body "hello"
 */
class DebugCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        EngineHolder.ensure(context)
        val extras = intent.extras ?: return
        val values = HashMap<String, Any?>()
        for (key in extras.keySet()) values[key] = extras.getString(key)
        EngineHolder.bridge.emit(values + ("type" to "debug_command"))
    }
}
