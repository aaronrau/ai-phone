package ai.local.receptionist.telephony

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import ai.local.receptionist.EngineHolder

/** Buttons on call notifications. Not exported. */
class CallActionReceiver : BroadcastReceiver() {
    companion object {
        const val TAKE_OVER = "ai.local.receptionist.TAKE_OVER"
        const val HANG_UP = "ai.local.receptionist.HANG_UP"
        const val ANSWER = "ai.local.receptionist.ANSWER"
        const val DECLINE = "ai.local.receptionist.DECLINE"
        const val SPEAKER = "ai.local.receptionist.SPEAKER"
        const val PICK_UP = "ai.local.receptionist.PICK_UP"
        const val NOT_NOW = "ai.local.receptionist.NOT_NOW"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra("callId") ?: return
        when (intent.action) {
            // Handled here so the buttons work even before the app's engine starts.
            ANSWER -> CallRegistry.answer(callId)
            DECLINE -> CallRegistry.reject(callId)
            HANG_UP -> CallRegistry.hangup(callId)
            SPEAKER -> CallRegistry.setSpeaker(!CallRegistry.isSpeaker())
            TAKE_OVER, PICK_UP, NOT_NOW -> {
                val action = when (intent.action) { PICK_UP -> "pick_up"; NOT_NOW -> "not_now"; else -> "take_over" }
                EngineHolder.ensure(context)
                EngineHolder.bridge.emit(mapOf("type" to "call_action", "action" to action, "callId" to callId))
            }
        }
    }
}
