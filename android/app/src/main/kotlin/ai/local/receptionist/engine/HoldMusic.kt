package ai.local.receptionist.engine

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Soft looping hold music, synthesised on the phone so there is no recording
 * to ship or license: a slow broken-chord progression (C, A minor, F, G) in a
 * mellow electric-piano tone over a quiet bass. Notes sit mostly between
 * 260 Hz and 1.1 kHz, which survives narrowband call codecs.
 */
class HoldMusic(private val rate: Int) {
    private companion object {
        /** MIDI notes, six per chord. */
        val ARPEGGIO = intArrayOf(
            72, 76, 79, 84, 79, 76,
            69, 72, 76, 81, 76, 72,
            65, 69, 72, 77, 72, 69,
            67, 71, 74, 79, 74, 71,
        )
        const val NOTE_MS = 450
        const val LEVEL = 0.16
        const val BASS_LEVEL = 0.07
        const val FADE_IN_MS = 600

        fun hz(midi: Int) = 440.0 * 2.0.pow((midi - 69) / 12.0)
    }

    private val noteSamples = rate * NOTE_MS / 1000
    private val chordSamples = noteSamples * 6
    private val loopSamples = noteSamples * ARPEGGIO.size
    private var position = 0L
    private var faded = 0

    /** Starts the next chunk with a short fade-in (after silence or speech). */
    fun fadeIn() { faded = 0 }

    /** The next [samples] samples as 16-bit little-endian mono PCM. */
    fun next(samples: Int): ByteArray {
        val out = ByteArray(samples * 2)
        val fadeSamples = rate * FADE_IN_MS / 1000
        for (i in 0 until samples) {
            val p = position % loopSamples
            var value = 0.0
            // The current note plus the tails of the two before it.
            val k = (p / noteSamples).toInt()
            for (back in 0..2) {
                val index = k - back
                val wrapped = ((index % ARPEGGIO.size) + ARPEGGIO.size) % ARPEGGIO.size
                val age = p - index.toLong() * noteSamples
                value += LEVEL * note(hz(ARPEGGIO[wrapped]), age)
            }
            // Bass: the chord root two octaves down, swelling in and out.
            val chord = (p / chordSamples).toInt()
            val inChord = (p % chordSamples).toDouble() / chordSamples
            val swell = sin(PI * inChord)
            val bass = hz(ARPEGGIO[chord * 6] - 24)
            val t = (p % chordSamples).toDouble() / rate
            value += BASS_LEVEL * swell * (sin(2 * PI * bass * t) + 0.5 * sin(4 * PI * bass * t))
            if (faded < fadeSamples) {
                value *= faded.toDouble() / fadeSamples
                faded++
            }
            val sample = (value * 32767).toInt().coerceIn(-32768, 32767)
            out[2 * i] = (sample and 0xff).toByte()
            out[2 * i + 1] = ((sample shr 8) and 0xff).toByte()
            position++
        }
        return out
    }

    /** One plucked note [age] samples after it started: fast attack, slow decay. */
    private fun note(frequency: Double, age: Long): Double {
        if (age < 0) return 0.0
        val t = age.toDouble() / rate
        val attack = min(1.0, t / 0.012)
        val envelope = attack * exp(-t / 0.55)
        if (envelope < 0.001) return 0.0
        val w = 2 * PI * frequency * t
        return envelope * (sin(w) + 0.3 * sin(2 * w) * exp(-t / 0.25) + 0.1 * sin(3 * w) * exp(-t / 0.15))
    }
}
