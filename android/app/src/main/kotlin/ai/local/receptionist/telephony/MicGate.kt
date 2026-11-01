package ai.local.receptionist.telephony

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Keeps the phone's microphone out of a call the assistant is handling.
 *
 * On most phones the call stays muted and the assistant's speech is injected
 * into the uplink after the mute. On some (Samsung), muting the call silences
 * the whole uplink, injected speech included, so the caller hears nothing.
 * There the microphone is opened only while speech or hold music is playing
 * into the call and closed again in every pause.
 */
class MicGate(
    /** Speech or hold music is playing into the call now (or within the lead time). */
    private val sounding: () -> Boolean,
    /** Assistant audio currently goes into the call through the helper. */
    private val bridged: () -> Boolean,
) {
    companion object {
        /** Phones whose call mute also silences audio played into the uplink. */
        val muteSilencesInjection: Boolean = Build.MANUFACTURER.equals("samsung", ignoreCase = true)

        /** Played audio reaches the uplink after the helper's buffers: keep the mic open a bit longer. */
        private const val TAIL_MS = 600L
    }

    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var wanted = false
    @Volatile private var mode = "auto"
    private var applied: Boolean? = null
    private var quietSince = 0L

    private val gated: Boolean
        get() = when (mode) {
            "always" -> false
            "while_silent" -> true
            else -> muteSilencesInjection
        }

    private val tick = object : Runnable {
        override fun run() {
            update()
            if (wanted && gated) handler.postDelayed(this, 40)
        }
    }

    /** The assistant wants the call muted ([on]) or the owner's microphone back. */
    fun want(on: Boolean, mode: String?) {
        handler.post {
            this.mode = mode ?: "auto"
            wanted = on
            applied = null
            handler.removeCallbacks(tick)
            tick.run()
        }
    }

    private fun update() {
        val mute = when {
            !wanted -> false
            !gated || !bridged() -> true
            sounding() -> { quietSince = 0; false }
            else -> {
                val now = SystemClock.elapsedRealtime()
                if (quietSince == 0L) quietSince = now
                // Stay open through the tail of what was just played.
                !(applied == false && now - quietSince < TAIL_MS)
            }
        }
        if (applied != mute) {
            CallRegistry.setMuted(mute)
            applied = mute
            if (Log.isLoggable("ReceptionistCall", Log.DEBUG)) Log.d("ReceptionistCall", "mic gate muted=$mute")
        }
    }
}
