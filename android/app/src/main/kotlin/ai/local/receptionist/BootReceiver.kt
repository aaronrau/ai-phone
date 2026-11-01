package ai.local.receptionist

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the receptionist runtime after reboot or app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ReceptionistService.start(context)
    }
}
