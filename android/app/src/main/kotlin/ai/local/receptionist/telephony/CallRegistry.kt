package ai.local.receptionist.telephony

import android.os.Build
import android.os.OutcomeReceiver
import android.telecom.Call
import android.telecom.CallEndpoint
import android.telecom.CallEndpointException
import android.util.Log
import java.util.concurrent.Executors
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.telecom.VideoProfile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Live calls known to the bound InCallService, addressed by stable string IDs. */
object CallRegistry {
    private val ids = AtomicInteger(0)
    private val calls = ConcurrentHashMap<String, Call>()
    @Volatile var service: InCallService? = null

    /** Numbers the receptionist will answer; their calls never pop up the app. */
    private val aiNumbers = ConcurrentHashMap<String, Long>()
    private val aiCalls = ConcurrentHashMap.newKeySet<String>()

    private fun key(number: String) = number.filter { it.isDigit() }.takeLast(10)

    fun markAiNumber(number: String) { aiNumbers[key(number)] = System.currentTimeMillis() }
    fun markAiCall(id: String) { aiCalls.add(id) }

    /** The owner took over: the call is theirs from now on. */
    fun unmarkAi(id: String, call: Call) { aiCalls.remove(id); aiNumbers.remove(key(number(call))) }

    fun isSpeaker(): Boolean = currentEndpoint?.endpointType == CallEndpoint.TYPE_SPEAKER

    fun isAi(id: String, call: Call): Boolean {
        if (aiCalls.contains(id)) return true
        val marked = aiNumbers[key(number(call))] ?: return false
        return System.currentTimeMillis() - marked < 60_000
    }

    fun add(call: Call): String {
        val id = "call-${ids.incrementAndGet()}"
        calls[id] = call
        return id
    }

    fun idOf(call: Call): String? = calls.entries.firstOrNull { it.value === call }?.key
    fun remove(call: Call) { idOf(call)?.let { calls.remove(it); aiCalls.remove(it) } }
    fun get(id: String): Call? = calls[id]
    fun all(): Map<String, Call> = calls.toMap()

    fun number(call: Call): String = call.details?.handle?.schemeSpecificPart ?: ""

    fun describe(id: String, call: Call): Map<String, Any?> = mapOf(
        "callId" to id,
        "number" to number(call),
        "state" to stateName(call.details?.state ?: Call.STATE_NEW),
        "incoming" to (call.details?.callDirection == Call.Details.DIRECTION_INCOMING),
    )

    fun answer(id: String) { get(id)?.answer(VideoProfile.STATE_AUDIO_ONLY) }
    fun hold(id: String) { get(id)?.hold() }
    fun unhold(id: String) { get(id)?.unhold() }

    /** A call other than [except] that the assistant is talking on right now. */
    fun liveAiCall(except: String): String? = calls.entries.firstOrNull { (id, call) ->
        id != except && aiCalls.contains(id) && call.details?.state == Call.STATE_ACTIVE
    }?.key

    fun reject(id: String) { get(id)?.reject(false, null) }
    fun hangup(id: String) {
        val call = get(id) ?: return
        if (call.details?.state == Call.STATE_RINGING) call.reject(false, null) else call.disconnect()
    }

    @Volatile var endpoints: List<CallEndpoint> = emptyList()
    @Volatile var currentEndpoint: CallEndpoint? = null
    private val endpointExecutor = Executors.newSingleThreadExecutor()

    @Suppress("DEPRECATION")
    fun setSpeaker(on: Boolean) {
        val target = if (on) CallEndpoint.TYPE_SPEAKER else CallEndpoint.TYPE_EARPIECE
        val endpoint = endpoints.firstOrNull { it.endpointType == target }
        Log.i("ReceptionistCall", "setSpeaker on=$on endpoint=${endpoint?.endpointType} available=${endpoints.map { it.endpointType }} current=${currentEndpoint?.endpointType}")
        val inCall = service
        if (endpoint != null && inCall != null && Build.VERSION.SDK_INT >= 34) {
            inCall.requestCallEndpointChange(endpoint, endpointExecutor, object : OutcomeReceiver<Void, CallEndpointException> {
                override fun onResult(result: Void?) { Log.i("ReceptionistCall", "endpoint change ok type=$target") }
                override fun onError(error: CallEndpointException) {
                    Log.w("ReceptionistCall", "endpoint change failed code=${error.code}; falling back to setAudioRoute")
                    inCall.setAudioRoute(if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_WIRED_OR_EARPIECE)
                }
            })
        } else {
            inCall?.setAudioRoute(if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_WIRED_OR_EARPIECE)
        }
    }

    val speakerActive: Boolean
        get() = currentEndpoint?.endpointType == CallEndpoint.TYPE_SPEAKER

    fun setMuted(on: Boolean) { service?.setMuted(on) }
    fun dtmf(id: String, digit: Char) {
        val call = get(id) ?: return
        call.playDtmfTone(digit); call.stopDtmfTone()
    }

    @Suppress("DEPRECATION")
    fun audioState(): Map<String, Any?> {
        val state = service?.callAudioState ?: return emptyMap()
        return mapOf("route" to state.route,
            "speaker" to (state.route == CallAudioState.ROUTE_SPEAKER || speakerActive),
            "endpoint" to currentEndpoint?.endpointType, "muted" to state.isMuted)
    }

    fun stateName(state: Int): String = when (state) {
        Call.STATE_NEW -> "new"
        Call.STATE_DIALING -> "dialing"
        Call.STATE_RINGING -> "ringing"
        Call.STATE_HOLDING -> "holding"
        Call.STATE_ACTIVE -> "active"
        Call.STATE_DISCONNECTED -> "disconnected"
        Call.STATE_CONNECTING -> "connecting"
        Call.STATE_DISCONNECTING -> "disconnecting"
        Call.STATE_SELECT_PHONE_ACCOUNT -> "select_account"
        Call.STATE_SIMULATED_RINGING -> "simulated_ringing"
        Call.STATE_AUDIO_PROCESSING -> "audio_processing"
        else -> "unknown"
    }

    val sdk = Build.VERSION.SDK_INT
}
