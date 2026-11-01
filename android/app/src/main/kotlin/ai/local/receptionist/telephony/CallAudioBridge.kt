package ai.local.receptionist.telephony

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * App side of the call-audio bridge. SELinux forbids sockets between the
 * shell user and apps, so the shell helper (ShellCallAudio) polls
 * [CallAudioProvider] every ~40 ms: each call delivers captured caller audio
 * and returns pending commands and speech to play into the call.
 */
class CallAudioBridge(private val emit: (Map<String, Any?>) -> Unit) {
    companion object {
        @Volatile var instance: CallAudioBridge? = null
        /** Bytes of 24 kHz PCM16 queued for the call before the renderer waits. */
        private const val MAX_QUEUED_BYTES = 24000 * 2
    }

    private val captured = ArrayBlockingQueue<ShortArray>(500)
    private val commands = ConcurrentLinkedQueue<String>()
    private val playback = LinkedBlockingQueue<ByteArray>()
    private val queuedBytes = AtomicLong(0)
    @Volatile private var lastExchange = 0L
    @Volatile private var wasConnected = false

    init { instance = this }

    val connected: Boolean get() = SystemClock.elapsedRealtime() - lastExchange < 1500

    /** Called by the provider on a binder thread. */
    fun exchange(extras: Bundle?): Bundle {
        lastExchange = SystemClock.elapsedRealtime()
        if (!wasConnected) {
            wasConnected = true
            Log.i("CallAudioBridge", "helper connected")
            emit(mapOf("type" to "bridge", "connected" to true))
        }
        extras?.getByteArray("pcm")?.let { bytes ->
            if (bytes.isNotEmpty()) {
                val pcm = ShortArray(bytes.size / 2) { i ->
                    ((bytes[2 * i].toInt() and 0xff) or (bytes[2 * i + 1].toInt() shl 8)).toShort()
                }
                if (!captured.offer(pcm)) { captured.poll(); captured.offer(pcm) }
            }
        }
        extras?.getString("event")?.let { event ->
            Log.i("CallAudioBridge", "helper: $event")
            emit(mapOf("type" to "bridge_event", "message" to event))
        }
        val reply = Bundle()
        val pending = buildList { while (true) add(commands.poll() ?: break) }
        if (pending.isNotEmpty()) reply.putStringArrayList("commands", ArrayList(pending))
        // Hand over up to ~250 ms of speech per exchange.
        var budget = 24000 / 4 * 2
        val out = java.io.ByteArrayOutputStream()
        while (budget > 0) {
            val chunk = playback.poll() ?: break
            out.write(chunk)
            budget -= chunk.size
            queuedBytes.addAndGet(-chunk.size.toLong())
        }
        if (out.size() > 0) reply.putByteArray("play", out.toByteArray())
        return reply
    }

    fun command(text: String) { commands.add(text) }

    fun startCapture(source: String = "voice_downlink") {
        captured.clear()
        command("capture_start $source")
    }

    fun stopCapture() { command("capture_stop"); captured.clear() }

    /** Next block of caller audio (16 kHz), or null after [timeoutMs]. */
    fun read(timeoutMs: Long): ShortArray? = captured.poll(timeoutMs, TimeUnit.MILLISECONDS)

    /** Queues 24 kHz PCM16 speech for the call, waiting while the queue is full. */
    fun play(frame: ByteArray): Boolean {
        while (queuedBytes.get() > MAX_QUEUED_BYTES) {
            if (!connected) return false
            Thread.sleep(10)
        }
        queuedBytes.addAndGet(frame.size.toLong())
        playback.add(frame)
        return true
    }

    fun flushPlayback() {
        playback.clear()
        queuedBytes.set(0)
        command("playback_flush")
    }
}

/** Shell-only (DUMP permission + uid check) endpoint for the call-audio helper. */
class CallAudioProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val uid = Binder.getCallingUid()
        if (uid != 2000 && uid != 0) throw SecurityException("Call audio is only available to the shell helper")
        if (method != "exchange") return null
        val bridge = CallAudioBridge.instance
        if (bridge == null) {
            // The helper is up but the app's runtime is not (e.g. right after an
            // update): start it, at most every 30 s.
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastStartAttempt > 30_000) {
                lastStartAttempt = now
                context?.let { ai.local.receptionist.ReceptionistService.start(it) }
            }
            return Bundle().apply { putBoolean("not_ready", true) }
        }
        return bridge.exchange(extras)
    }

    private var lastStartAttempt = 0L

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                       selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
