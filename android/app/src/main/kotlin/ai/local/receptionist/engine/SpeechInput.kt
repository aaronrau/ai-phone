package ai.local.receptionist.engine

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.File
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Microphone → Silero VAD → Whisper. Emits one transcript per detected
 * utterance. Input is ignored while [isOutputActive] reports that our own
 * speech may still be audible, so the receptionist never transcribes itself.
 */
class SpeechInput(
    modelDirectory: File,
    requestedModel: String,
    private val emit: (Map<String, Any?>) -> Unit,
    private val isOutputActive: () -> Boolean,
) {
    companion object {
        const val SAMPLE_RATE = 16000
        private const val WINDOW = 512
        // Whisper's non-speech annotations, e.g. "(b", "[BLANK_AUDIO]", "(music)".
        private val NOISE = Regex("""^[\s\p{Punct}]*$|^\s*[\[(*].*$""")
    }

    val modelName: String
    private val recognizer: OfflineRecognizer
    private val vadConfig: VadModelConfig
    @Volatile private var running = false
    private var thread: Thread? = null
    @Volatile var endSilenceSeconds = 0.8f

    /** True when the input cannot contain our own speech (the call downlink),
     *  so listening continues while the receptionist talks (barge-in). */
    @Volatile var ignoreOutput = false
    @Volatile var minRmsDb = -60.0

    init {
        val (name, modelConfig) = recognizerConfig(modelDirectory, requestedModel)
        modelName = name
        recognizer = OfflineRecognizer(
            config = OfflineRecognizerConfig(
                featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                modelConfig = modelConfig,
            ),
        )
        vadConfig = VadModelConfig(
            sileroVadModelConfig = SileroVadModelConfig(
                model = File(modelDirectory, "vad/silero_vad.onnx").path,
                threshold = 0.5f,
                minSilenceDuration = endSilenceSeconds,
                minSpeechDuration = 0.25f,
                windowSize = WINDOW,
                maxSpeechDuration = 20f,
            ),
            sampleRate = SAMPLE_RATE,
            numThreads = 1,
        )
        Log.i("SpeechInput", "stt=$modelName ready")
    }

    val listening: Boolean get() = running

    /** Transcribes a complete PCM float buffer; used by tests and diagnostics. */
    fun transcribe(samples: FloatArray): String {
        val stream = recognizer.createStream()
        try {
            stream.acceptWaveform(samples, SAMPLE_RATE)
            recognizer.decode(stream)
            return recognizer.getResult(stream).text.trim()
        } finally { stream.release() }
    }

    /** Supplies 16 kHz PCM16 blocks; returns null on timeout. */
    fun interface PcmFeed { fun read(timeoutMs: Long): ShortArray? }

    @SuppressLint("MissingPermission")
    fun start(source: Int, sessionId: String) {
        stop()
        ignoreOutput = false
        running = true
        thread = Thread({ capture(source, sessionId) }, "speech-input").apply { start() }
    }

    /** Listens to an external stream (the call-audio bridge) instead of a microphone. */
    fun startFeed(feed: PcmFeed, sessionId: String) {
        stop()
        ignoreOutput = true
        running = true
        thread = Thread({ listen(sessionId, null, feed) }, "speech-input").apply { start() }
    }

    fun stop() {
        running = false
        thread?.join(2000)
        thread = null
    }

    @SuppressLint("MissingPermission")
    private fun capture(source: Int, sessionId: String) {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT)
        val record = try {
            AudioRecord(source, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuffer, SAMPLE_RATE))
        } catch (failure: Throwable) {
            emit(mapOf("type" to "listen_error", "session" to sessionId, "message" to (failure.message ?: "Microphone unavailable")))
            running = false
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            emit(mapOf("type" to "listen_error", "session" to sessionId, "message" to "Microphone source $source unavailable"))
            record.release(); running = false; return
        }
        listen(sessionId, record, null)
    }

    private fun listen(sessionId: String, record: AudioRecord?, feed: PcmFeed?) {
        vadConfig.sileroVadModelConfig.minSilenceDuration = endSilenceSeconds
        val vad = Vad(config = vadConfig)
        val pcm = ShortArray(WINDOW)
        val samples = FloatArray(WINDOW)
        var speaking = false
        var muted = false
        var levelAt = 0L
        var peakDb = -120.0
        record?.startRecording()
        emit(mapOf("type" to "listen_started", "session" to sessionId, "source" to (if (record == null) "bridge" else "mic")))
        var pending = ShortArray(0)
        try {
            while (running) {
                val count = if (record != null) record.read(pcm, 0, WINDOW) else {
                    // Re-block the bridge's 20 ms frames into VAD windows.
                    while (pending.size < WINDOW && running) {
                        val block = feed!!.read(200) ?: break
                        pending += block
                    }
                    if (pending.size < WINDOW) 0 else {
                        pending.copyInto(pcm, 0, 0, WINDOW)
                        pending = pending.copyOfRange(WINDOW, pending.size)
                        WINDOW
                    }
                }
                if (count <= 0) continue
                var energy = 0.0
                for (i in 0 until count) {
                    val v = pcm[i] / 32768f
                    samples[i] = v
                    energy += v * v
                }
                val db = 10 * log10((energy / count).coerceAtLeast(1e-12))
                if (db > peakDb) peakDb = db
                val now = SystemClock.elapsedRealtime()
                if (now - levelAt > 1000) {
                    emit(mapOf("type" to "level", "session" to sessionId, "peakDb" to peakDb, "muted" to muted))
                    levelAt = now; peakDb = -120.0
                }
                if (!ignoreOutput && isOutputActive()) {
                    if (!muted) { vad.reset(); vad.clear(); speaking = false; muted = true }
                    continue
                }
                if (muted) { vad.reset(); muted = false }
                vad.acceptWaveform(if (count == WINDOW) samples else samples.copyOf(count))
                val detected = vad.isSpeechDetected()
                if (detected && !speaking) {
                    speaking = true
                    emit(mapOf("type" to "speech_start", "session" to sessionId))
                }
                while (!vad.empty()) {
                    val segment = vad.front()
                    vad.pop()
                    speaking = false
                    handleSegment(segment.samples, sessionId)
                }
            }
        } catch (failure: Throwable) {
            Log.e("SpeechInput", "capture failed", failure)
            emit(mapOf("type" to "listen_error", "session" to sessionId, "message" to (failure.message ?: "Capture failed")))
        } finally {
            record?.let { runCatching { it.stop() }; it.release() }
            // The line dropped mid-sentence (e.g. the other side said "you're booked"
            // and hung up): transcribe what was heard so it is not lost.
            if (speaking) runCatching {
                vad.flush()
                while (!vad.empty()) {
                    val segment = vad.front()
                    vad.pop()
                    handleSegment(segment.samples, sessionId, final = true)
                }
            }.onFailure { Log.w("SpeechInput", "final flush failed", it) }
            vad.release()
            running = false
            emit(mapOf("type" to "listen_stopped", "session" to sessionId))
        }
    }

    private fun handleSegment(segment: FloatArray, sessionId: String, final: Boolean = false) {
        var energy = 0.0
        for (v in segment) energy += v * v
        val rms = sqrt(energy / segment.size.coerceAtLeast(1))
        val db = 20 * log10(rms.coerceAtLeast(1e-9))
        if (db < minRmsDb) {
            emit(mapOf("type" to "speech_discarded", "session" to sessionId, "audioMs" to segment.size * 1000L / SAMPLE_RATE))
            return
        }
        val start = SystemClock.elapsedRealtime()
        // Drop Whisper sound annotations such as "(buzzer)" or "[MUSIC]".
        val text = transcribe(segment).replace(Regex("""\([^)]*\)|\[[^]]*]|\*[^*]*\*"""), " ")
            .replace(Regex("""\s+"""), " ").trim()
        val ms = SystemClock.elapsedRealtime() - start
        val audioMs = segment.size * 1000L / SAMPLE_RATE
        Log.i("SpeechInput", "utterance audioMs=$audioMs sttMs=$ms chars=${text.length}")
        if (text.isBlank() || NOISE.matches(text)) {
            emit(mapOf("type" to "speech_discarded", "session" to sessionId, "audioMs" to audioMs))
            return
        }
        emit(mapOf("type" to "utterance", "session" to sessionId, "text" to text,
            "audioMs" to audioMs, "sttMs" to ms, "rmsDb" to db, "final" to final))
    }
}

/**
 * Speech-to-text model selection. Parakeet (NVIDIA NeMo, via sherpa-onnx) is
 * the default: `parakeet-0.6b` (TDT transducer, int8) or the lower-memory
 * `parakeet-110m` (CTC, int8). Whisper exports remain as a fallback.
 */
fun recognizerConfig(modelDirectory: File, requested: String): Pair<String, OfflineModelConfig> {
    val threads = 4
    fun parakeet(name: String): OfflineModelConfig? {
        val dir = File(modelDirectory, name)
        val tokens = File(dir, "tokens.txt").takeIf { it.isFile } ?: return null
        val encoder = File(dir, "encoder.int8.onnx")
        if (encoder.isFile) {
            return OfflineModelConfig(
                transducer = com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig(
                    encoder = encoder.path,
                    decoder = File(dir, "decoder.int8.onnx").path,
                    joiner = File(dir, "joiner.int8.onnx").path,
                ),
                tokens = tokens.path, numThreads = threads, modelType = "nemo_transducer",
            )
        }
        val model = File(dir, "model.int8.onnx").takeIf { it.isFile } ?: return null
        return OfflineModelConfig(
            nemo = com.k2fsa.sherpa.onnx.OfflineNemoEncDecCtcModelConfig(model = model.path),
            tokens = tokens.path, numThreads = threads,
        )
    }
    fun whisper(name: String): OfflineModelConfig? {
        val dir = File(modelDirectory, "whisper")
        fun part(kind: String) =
            listOf("$name-$kind.int8.onnx", "$name-$kind.onnx").map { File(dir, it) }.firstOrNull { it.isFile }
        val encoder = part("encoder") ?: return null
        val decoder = part("decoder") ?: return null
        return OfflineModelConfig(
            whisper = OfflineWhisperModelConfig(encoder = encoder.path, decoder = decoder.path, language = "en", tailPaddings = 1000),
            tokens = File(dir, "$name-tokens.txt").path, numThreads = threads, modelType = "whisper",
        )
    }
    for (name in listOf(requested, "parakeet-0.6b", "parakeet-110m", "base.en", "small.en", "tiny.en").distinct()) {
        val config = if (name.startsWith("parakeet")) parakeet(name) else whisper(name)
        if (config != null) return name to config
    }
    error("No speech-to-text model is provisioned")
}

/** Android capture source names accepted from Dart. */
object CaptureSources {
    fun parse(name: String?): Int = when (name) {
        "voice_communication" -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
        "voice_recognition" -> MediaRecorder.AudioSource.VOICE_RECOGNITION
        "unprocessed" -> MediaRecorder.AudioSource.UNPROCESSED
        "camcorder" -> MediaRecorder.AudioSource.CAMCORDER
        "voice_call" -> MediaRecorder.AudioSource.VOICE_CALL
        "voice_downlink" -> MediaRecorder.AudioSource.VOICE_DOWNLINK
        "voice_uplink" -> MediaRecorder.AudioSource.VOICE_UPLINK
        else -> MediaRecorder.AudioSource.MIC
    }
}

object PlaybackUsages {
    fun parse(name: String?): Int = when (name) {
        "voice_communication" -> android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION
        "assistant" -> android.media.AudioAttributes.USAGE_ASSISTANT
        "alarm" -> android.media.AudioAttributes.USAGE_ALARM
        "notification" -> android.media.AudioAttributes.USAGE_NOTIFICATION
        "accessibility" -> android.media.AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY
        else -> android.media.AudioAttributes.USAGE_MEDIA
    }
}
