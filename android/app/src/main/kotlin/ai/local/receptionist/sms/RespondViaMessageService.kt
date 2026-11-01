package ai.local.receptionist.sms

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.telephony.TelephonyManager

/** "Reply with a text" from the incoming-call screen. */
class RespondViaMessageService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == TelephonyManager.ACTION_RESPOND_VIA_MESSAGE) {
            val number = intent.data?.schemeSpecificPart?.substringBefore('?')
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!number.isNullOrBlank() && !text.isNullOrBlank()) {
                Thread { runCatching { SmsStore.send(this, number, text) } }.start()
            }
        }
        stopSelf(startId)
        return START_NOT_STICKY
    }
}
