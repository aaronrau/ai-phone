package ai.local.receptionist.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import ai.local.receptionist.EngineHolder
import ai.local.receptionist.ReceptionistService

/**
 * Incoming texts. As the default messaging app this handles SMS_DELIVER (the
 * text is saved to the system store here); otherwise SMS_RECEIVED, which the
 * default app also gets. Each text (multipart bodies joined) goes to Dart.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val deliver = intent.action == Telephony.Sms.Intents.SMS_DELIVER_ACTION
        if (!deliver && intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        // The default app gets both broadcasts; act on SMS_DELIVER only.
        if (!deliver && SmsStore.isDefault(context)) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val bySender = LinkedHashMap<String, StringBuilder>()
        var time = System.currentTimeMillis()
        for (message in messages) {
            val sender = message.displayOriginatingAddress ?: message.originatingAddress ?: continue
            bySender.getOrPut(sender) { StringBuilder() }.append(message.displayMessageBody ?: "")
            time = message.timestampMillis
        }
        val subscription = intent.getIntExtra("subscription", -1)
        val pending = goAsync()
        Thread {
            try {
                val saved = bySender.map { (sender, body) ->
                    Triple(sender, body.toString(), SmsStore.saveIncoming(context, sender, body.toString(), time, subscription))
                }
                ReceptionistService.start(context)
                EngineHolder.ensure(context)
                for ((sender, body, thread) in saved) {
                    EngineHolder.bridge.emit(mapOf("type" to "sms", "number" to sender, "body" to body,
                        "time" to time, "threadId" to thread, "stored" to deliver))
                }
            } finally {
                pending.finish()
            }
        }.start()
    }
}
