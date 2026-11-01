package ai.local.receptionist.telephony

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.os.SystemClock
import android.util.Log
import ai.local.receptionist.engine.CaptureSources
import ai.local.receptionist.engine.PlaybackUsages
import ai.local.receptionist.engine.SpeechInput
import ai.local.receptionist.engine.SpeechOutput
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.log10

/**
 * Measures which capture sources hear the caller and which playback usages
 * reach the caller on this specific phone during a live call. Results are
 * levels, silenced flags and on-device transcripts; WAVs stay app-private.
 */
object CallAudioProbe {
    private val captureOrder = listOf("voice_recognition", "voice_downlink", "voice_call", "mic",
        "unprocessed", "voice_communication", "voice_uplink")
    private val playbackOrder = listOf("media", "voice_communication", "assistant", "alarm", "accessibility")

    @SuppressLint("MissingPermission")
    fun run(context: Context, input: SpeechInput, output: SpeechOutput, voice: String,
            emit: (Map<String, Any?>) -> Unit): List<Map<String, Any?>> {
        val results = ArrayList<Map<String, Any?>>()
        val directory = File(context.filesDir, "probe").apply { mkdirs() }
        val originalUsage = output.usage
        fun log(map: Map<String, Any?>) {
            Log.i("CallAudioProbe", map.toString())
            results.add(map)
            emit(map + ("type" to "probe_result"))
        }
        val audioManager = context.getSystemService(AudioManager::class.java)
        log(mapOf("source" to "route", "audio" to CallRegistry.audioState().toString(),
            "mode" to audioManager.mode, "callScreeningMode" to audioManager.isCallScreeningModeSupported,
            "calls" to CallRegistry.all().map { CallRegistry.stateName(it.value.details?.state ?: 0) }))
        output.usage = PlaybackUsages.parse("voice_communication")
        output.speakAndWait("probe-intro", "This is an audio test. Please keep talking until I say the test is finished.", voice)
        for (name in captureOrder) {
            log(record(context, name, if (name == "voice_recognition") 5000 else 3000, directory, input))
        }
        for ((index, usage) in playbackOrder.withIndex()) {
            output.usage = PlaybackUsages.parse(usage)
            val recorder = Thread {
                log(record(context, "voice_recognition", 3000, directory, input, "loopback-$usage") + ("playbackUsage" to usage))
            }
            recorder.start()
            output.speakAndWait("probe-play-$index", "Playback test number ${index + 1}.", voice)
            recorder.join(6000)
        }
        output.usage = PlaybackUsages.parse("voice_communication")
        output.speakAndWait("probe-end", "The test is finished. Thank you.", voice)
        output.usage = originalUsage
        return results
    }

    @SuppressLint("MissingPermission")
    private fun record(context: Context, name: String, durationMs: Int, directory: File,
                       input: SpeechInput, label: String = name): Map<String, Any?> {
        val rate = SpeechInput.SAMPLE_RATE
        val record = try {
            AudioRecord(CaptureSources.parse(name), rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, rate * 2)
        } catch (failure: Throwable) {
            return mapOf("source" to label, "ok" to false, "error" to (failure.message ?: failure.javaClass.simpleName))
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return mapOf("source" to label, "ok" to false, "error" to "not initialized")
        }
        val total = rate * durationMs / 1000
        val pcm = ShortArray(total)
        var offset = 0
        var silenced: Boolean? = null
        try {
            record.startRecording()
            val deadline = SystemClock.elapsedRealtime() + durationMs + 1500
            while (offset < total && SystemClock.elapsedRealtime() < deadline) {
                val n = record.read(pcm, offset, minOf(1024, total - offset))
                if (n < 0) break
                offset += n
                if (silenced == null && offset > rate / 2) {
                    val manager = context.getSystemService(AudioManager::class.java)
                    silenced = manager.activeRecordingConfigurations
                        .firstOrNull { it.clientAudioSessionId == record.audioSessionId }?.isClientSilenced
                }
            }
        } catch (failure: Throwable) {
            return mapOf("source" to label, "ok" to false, "error" to (failure.message ?: "read failed"))
        } finally {
            runCatching { record.stop() }
            record.release()
        }
        val floats = FloatArray(offset) { pcm[it] / 32768f }
        var energy = 0.0
        var peak = 0f
        for (v in floats) { energy += v * v; if (kotlin.math.abs(v) > peak) peak = kotlin.math.abs(v) }
        val rmsDb = 10 * log10((energy / offset.coerceAtLeast(1)).coerceAtLeast(1e-12))
        writeWav(File(directory, "$label.wav"), pcm, offset, rate)
        val transcript = runCatching { if (offset > rate / 2) input.transcribe(floats) else "" }.getOrDefault("")
        return mapOf("source" to label, "ok" to true, "samples" to offset,
            "rmsDb" to "%.1f".format(rmsDb), "peak" to "%.3f".format(peak),
            "silenced" to silenced, "transcript" to transcript)
    }

    private fun writeWav(file: File, pcm: ShortArray, count: Int, rate: Int) {
        RandomAccessFile(file, "rw").use { out ->
            out.setLength(0)
            val data = count * 2
            fun i32(v: Int) { out.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())) }
            fun i16(v: Int) { out.write(byteArrayOf(v.toByte(), (v shr 8).toByte())) }
            out.writeBytes("RIFF"); i32(36 + data); out.writeBytes("WAVEfmt ")
            i32(16); i16(1); i16(1); i32(rate); i32(rate * 2); i16(2); i16(16)
            out.writeBytes("data"); i32(data)
            val bytes = ByteArray(data)
            for (i in 0 until count) { bytes[2 * i] = pcm[i].toInt().toByte(); bytes[2 * i + 1] = (pcm[i].toInt() shr 8).toByte() }
            out.write(bytes)
        }
    }
}
