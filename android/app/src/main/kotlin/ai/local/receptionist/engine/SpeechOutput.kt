package ai.local.receptionist.engine

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Ordered speech queue: renders each queued sentence with Pocket and streams it
 * into one AudioTrack, so the next sentence renders while the previous plays.
 */
class SpeechOutput(private val sink: (Map<String, Any?>) -> Unit) {
    private val waiters = ConcurrentHashMap<String, CountDownLatch>()

    private fun emit(event: Map<String, Any?>) {
        if (event["type"] == "tts_done" || event["type"] == "tts_error") {
            (event["id"] as? String)?.let { waiters.remove(it)?.countDown() }
        }
        sink(event)
    }

    /** Speaks and blocks until the utterance has played (diagnostics only). */
    fun speakAndWait(id: String, text: String, voice: String, timeoutMs: Long = 30_000) {
        val latch = CountDownLatch(1)
        waiters[id] = latch
        speak(id, text, voice)
        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
    }

    private data class Item(val id: String, val text: String, val voice: String, val generation: Long)

    @Volatile var tts: PocketTts? = null

    /** When set, speech goes into the phone call through the bridge instead of a local AudioTrack. */
    @Volatile var bridgeSink: ((ByteArray) -> Boolean)? = null
    private var bridgeClockStart = 0L
    private var bridgeSamples = 0L
    @Volatile var usage: Int = AudioAttributes.USAGE_MEDIA
    @Volatile var gain: Float = 1.0f
    private val queue = LinkedBlockingQueue<Item>()
    private val generation = AtomicLong(0)
    @Volatile private var track: AudioTrack? = null
    @Volatile private var trackUsage = -1
    @Volatile private var written = 0L
    @Volatile private var rendering = false
    /** Wall-clock time until which output may still be audible. */
    @Volatile var audibleUntil = 0L
        private set

    /** Hold music fills every pause in speech while this is set (a caller on hold). */
    @Volatile var holdMusic = false
        set(value) {
            if (value && !field) music.fadeIn()
            field = value
        }
    private val music = HoldMusic(PocketTts.SAMPLE_RATE)
    /** Wall-clock time the music written so far runs until. */
    @Volatile private var musicUntil = 0L

    private val worker = Thread({ loop() }, "speech-output").apply { isDaemon = true; start() }

    /** Speech or hold music is audible now, or queued to be within the lead time. */
    val sounding: Boolean get() = SystemClock.elapsedRealtime().let { it < audibleUntil || it < musicUntil }

    val active: Boolean get() = rendering || queue.isNotEmpty() || SystemClock.elapsedRealtime() < audibleUntil

    fun speak(id: String, text: String, voice: String) {
        queue.put(Item(id, text, voice, generation.get()))
    }

    /** Drops queued speech and silences current playback immediately. */
    fun stop() {
        generation.incrementAndGet()
        queue.clear()
        tts?.cancel()
        track?.let { runCatching { it.pause(); it.flush() } }
        written = 0
        audibleUntil = SystemClock.elapsedRealtime()
        musicUntil = 0
        music.fadeIn()
    }

    private fun ensureTrack(): AudioTrack {
        val existing = track
        if (existing != null && trackUsage == usage) return existing
        existing?.let { runCatching { it.stop(); it.release() } }
        val attributes = AudioAttributes.Builder()
            .setUsage(usage)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(PocketTts.SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .build()
        val created = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setBufferSizeInBytes(PocketTts.SAMPLE_RATE * 2) // one second
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track = created
        trackUsage = usage
        written = 0
        return created
    }

    private fun loop() {
        while (true) {
            val item = queue.poll(if (holdMusic) 20L else 250L, TimeUnit.MILLISECONDS)
            if (item == null) {
                if (holdMusic) runCatching { playMusic() }.onFailure { Log.w("SpeechOutput", "hold music failed", it) }
                continue
            }
            if (item.generation != generation.get()) continue
            val engine = tts
            if (engine == null) {
                emit(mapOf("type" to "tts_error", "id" to item.id, "message" to "Speech model not loaded"))
                continue
            }
            rendering = true
            val start = SystemClock.elapsedRealtime()
            var firstFrame = -1L
            try {
                val sink = bridgeSink
                if (sink != null) {
                    renderToBridge(engine, item, sink, start)
                    continue
                }
                val audio = ensureTrack()
                if (audio.playState != AudioTrack.PLAYSTATE_PLAYING) {
                    // Resynchronise frame accounting after a stop/flush.
                    written = audio.playbackHeadPosition.toLong() and 0xffffffffL
                    audio.play()
                }
                val finished = engine.render(item.text, item.voice) { frame ->
                    if (item.generation != generation.get()) return@render
                    if (firstFrame < 0) firstFrame = SystemClock.elapsedRealtime() - start
                    val scaled = applyGain(frame)
                    audio.write(scaled, 0, scaled.size)
                    written += scaled.size / 2
                    val head = audio.playbackHeadPosition.toLong() and 0xffffffffL
                    val pendingMs = ((written - head).coerceAtLeast(0) * 1000) / PocketTts.SAMPLE_RATE
                    audibleUntil = SystemClock.elapsedRealtime() + pendingMs + 150
                }
                if (item.generation != generation.get() || !finished) {
                    emit(mapOf("type" to "tts_done", "id" to item.id, "cancelled" to true))
                } else {
                    // Wait until this item's last frame has actually played.
                    val target = written
                    val deadline = SystemClock.elapsedRealtime() + 30_000
                    while (item.generation == generation.get() && SystemClock.elapsedRealtime() < deadline) {
                        val head = audio.playbackHeadPosition.toLong() and 0xffffffffL
                        if (head >= target) break
                        Thread.sleep(15)
                    }
                    audibleUntil = SystemClock.elapsedRealtime() + 150
                    Log.d("SpeechOutput", "spoke id=${item.id} firstFrameMs=$firstFrame totalMs=${SystemClock.elapsedRealtime() - start}")
                    emit(mapOf("type" to "tts_done", "id" to item.id, "cancelled" to false,
                        "firstFrameMs" to firstFrame))
                }
            } catch (failure: Throwable) {
                Log.e("SpeechOutput", "speech failed", failure)
                emit(mapOf("type" to "tts_error", "id" to item.id, "message" to (failure.message ?: "Speech failed")))
            } finally {
                rendering = false
            }
        }
    }

    /** Streams into the call. The helper's AudioTrack paces delivery; playback
     *  progress is estimated from the audio duration sent. */
    private fun renderToBridge(engine: PocketTts, item: Item, sink: (ByteArray) -> Boolean, start: Long) {
        var firstFrame = -1L
        var audioSamples = 0L
        val finished = engine.render(item.text, item.voice) { frame ->
            if (item.generation != generation.get()) return@render
            audioSamples += frame.size / 2
            val now = SystemClock.elapsedRealtime()
            if (firstFrame < 0) firstFrame = now - start
            // Speech starts after anything already queued: earlier speech or hold music.
            if (now > audibleUntil) { bridgeClockStart = maxOf(now, musicUntil); bridgeSamples = 0 }
            sink(applyGain(frame))
            bridgeSamples += frame.size / 2
            audibleUntil = bridgeClockStart + bridgeSamples * 1000 / PocketTts.SAMPLE_RATE + 250
        }
        if (item.generation != generation.get() || !finished) {
            emit(mapOf("type" to "tts_done", "id" to item.id, "cancelled" to true))
            return
        }
        val renderMs = SystemClock.elapsedRealtime() - start
        while (item.generation == generation.get() && SystemClock.elapsedRealtime() < audibleUntil - 100) Thread.sleep(15)
        Log.d("SpeechOutput", "spoke(bridge) id=${item.id} firstFrameMs=$firstFrame renderMs=$renderMs " +
            "audioMs=${audioSamples * 1000 / PocketTts.SAMPLE_RATE} totalMs=${SystemClock.elapsedRealtime() - start}")
        emit(mapOf("type" to "tts_done", "id" to item.id, "cancelled" to false, "firstFrameMs" to firstFrame))
    }

    /** Keeps about 300 ms of hold music queued; speech always goes first. */
    private fun playMusic() {
        val now = SystemClock.elapsedRealtime()
        // A short breath after each sentence before the music comes back.
        if (now < audibleUntil + 600) {
            music.fadeIn()
            return
        }
        if (musicUntil < now) musicUntil = now
        if (musicUntil - now > 300) return
        val chunk = applyGain(music.next(PocketTts.SAMPLE_RATE / 10))
        val sink = bridgeSink
        if (sink != null) {
            sink(chunk)
        } else {
            val audio = ensureTrack()
            if (audio.playState != AudioTrack.PLAYSTATE_PLAYING) {
                written = audio.playbackHeadPosition.toLong() and 0xffffffffL
                audio.play()
            }
            audio.write(chunk, 0, chunk.size)
            written += chunk.size / 2
        }
        musicUntil += 100
    }

    private fun applyGain(frame: ByteArray): ByteArray {
        if (gain == 1.0f) return frame
        val out = ByteArray(frame.size)
        var i = 0
        while (i + 1 < frame.size) {
            val sample = ((frame[i + 1].toInt() shl 8) or (frame[i].toInt() and 0xff)).toShort()
            val scaled = (sample * gain).toInt().coerceIn(-32768, 32767)
            out[i] = (scaled and 0xff).toByte()
            out[i + 1] = ((scaled shr 8) and 0xff).toByte()
            i += 2
        }
        return out
    }
}
