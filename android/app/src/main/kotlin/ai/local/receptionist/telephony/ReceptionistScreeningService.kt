package ai.local.receptionist.telephony

import android.os.Handler
import android.os.Looper
import android.telecom.Call
import android.telecom.CallScreeningService
import ai.local.receptionist.EngineHolder

/**
 * Asks the Dart policy whether to block, silently hand to the receptionist, or
 * ring normally. If no decision arrives in time the call rings normally.
 */
class ReceptionistScreeningService : CallScreeningService() {
    private val main = Handler(Looper.getMainLooper())

    override fun onScreenCall(details: Call.Details) {
        if (details.callDirection != Call.Details.DIRECTION_INCOMING) {
            respondToCall(details, CallResponse.Builder().build())
            return
        }
        val number = details.handle?.schemeSpecificPart ?: ""
        var answered = false
        val respond = { decision: String ->
            if (!answered) {
                answered = true
                val builder = CallResponse.Builder()
                when (decision) {
                    "reject" -> builder.setDisallowCall(true).setRejectCall(true)
                        .setSkipNotification(false).setSkipCallLog(false)
                    "silence" -> builder.setSilenceCall(true)
                }
                runCatching { respondToCall(details, builder.build()) }
            }
        }
        EngineHolder.ensure(this)
        EngineHolder.bridge.requestScreening(number, details.handlePresentation) { decision ->
            main.post { respond(decision) }
        }
        main.postDelayed({ respond("allow") }, 4000)
    }
}
