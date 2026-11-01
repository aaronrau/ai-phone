package ai.local.receptionist.telephony

import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.CallEndpoint
import android.util.Log
import android.telecom.InCallService
import ai.local.receptionist.EngineHolder
import ai.local.receptionist.ReceptionistService

/**
 * Default-phone-app call surface. Every call event is forwarded to the Dart
 * runtime, which decides whether the receptionist answers it.
 */
class ReceptionistInCallService : InCallService() {
    private val callbacks = HashMap<Call, Call.Callback>()

    override fun onCreate() {
        super.onCreate()
        CallRegistry.service = this
        EngineHolder.ensure(this)
        ReceptionistService.start(this)
    }

    override fun onDestroy() {
        if (CallRegistry.service === this) CallRegistry.service = null
        super.onDestroy()
    }

    override fun onCallAdded(call: Call) {
        val id = CallRegistry.add(call)
        val callback = object : Call.Callback() {
            override fun onStateChanged(call: Call, state: Int) {
                Log.i("ReceptionistCall", "call $id state=${CallRegistry.stateName(state)}")
                EngineHolder.bridge.emit(CallRegistry.describe(id, call) + ("type" to "call_state"))
                // With several calls, show whichever needs the owner most.
                CallNotifications.refresh(this@ReceptionistInCallService)
            }
        }
        callbacks[call] = callback
        call.registerCallback(callback)
        EngineHolder.bridge.emit(CallRegistry.describe(id, call) + ("type" to "call_added"))
        if (CallRegistry.isAi(id, call)) CallRegistry.markAiCall(id)
        CallNotifications.refresh(this)
        // Calls are shown as notifications; the app's call screen opens only
        // when the notification is tapped or the call was placed from the app.
    }

    override fun onCallRemoved(call: Call) {
        val id = CallRegistry.idOf(call)
        callbacks.remove(call)?.let { call.unregisterCallback(it) }
        CallRegistry.remove(call)
        if (id != null) EngineHolder.bridge.emit(mapOf("type" to "call_removed", "callId" to id))
        CallNotifications.refresh(this)
        if (CallRegistry.all().isEmpty()) ReceptionistService.leaveCallMode(this)
    }

    override fun onCallEndpointChanged(callEndpoint: CallEndpoint) {
        CallRegistry.currentEndpoint = callEndpoint
        Log.i("ReceptionistCall", "endpoint changed type=${callEndpoint.endpointType}")
        // Keep the Speaker button label in step with the audio route.
        CallNotifications.refresh(this)
        EngineHolder.bridge.emit(mapOf("type" to "call_audio", "speaker" to (callEndpoint.endpointType == CallEndpoint.TYPE_SPEAKER),
            "endpoint" to callEndpoint.endpointType))
    }

    override fun onAvailableCallEndpointsChanged(availableEndpoints: MutableList<CallEndpoint>) {
        CallRegistry.endpoints = availableEndpoints.toList()
        Log.i("ReceptionistCall", "available endpoints=${availableEndpoints.map { it.endpointType }}")
    }

    @Deprecated("Deprecated in Java")
    override fun onCallAudioStateChanged(audioState: CallAudioState?) {
        Log.i("ReceptionistCall", "audio state route=${audioState?.route} muted=${audioState?.isMuted}")
        EngineHolder.bridge.emit(mapOf("type" to "call_audio", "route" to audioState?.route,
            "speaker" to (audioState?.route == CallAudioState.ROUTE_SPEAKER),
            "muted" to audioState?.isMuted))
    }
}
