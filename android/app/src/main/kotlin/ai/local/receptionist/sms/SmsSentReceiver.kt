package ai.local.receptionist.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import ai.local.receptionist.EngineHolder

/** Marks a sent text as sent or failed once the radio reports back. */
class SmsSentReceiver : BroadcastReceiver() {
    companion object { const val EXTRA_LAST = "last_part" }

    override fun onReceive(context: Context, intent: Intent) {
        val uri = intent.data ?: return
        val ok = resultCode == Activity.RESULT_OK
        android.util.Log.i("SmsStore", "sent result=$resultCode")
        if (!ok || intent.getBooleanExtra(EXTRA_LAST, true)) {
            SmsStore.markSent(context, uri, ok)
            EngineHolder.bridge.emit(mapOf("type" to "sms_sent", "ok" to ok))
        }
    }
}
