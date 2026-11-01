package ai.local.receptionist.shell

import android.annotation.SuppressLint
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Looper
import android.os.Process
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.log10

/**
 * Call-audio helper that runs as the adb shell user, which holds
 * CAPTURE_AUDIO_OUTPUT, CALL_AUDIO_INTERCEPTION and MODIFY_AUDIO_ROUTING:
 *
 *   adb shell "CLASSPATH=$(pm path ai.local.receptionist | cut -d: -f2) \
 *       app_process /system/bin ai.local.receptionist.shell.ShellCallAudio bridge"
 *
 * In `bridge` mode it exchanges audio with the app's shell-only
 * CallAudioProvider every 40 ms: the caller's audio (VOICE_DOWNLINK, 16 kHz
 * PCM16) goes to the app, and the app's speech (24 kHz PCM16) is played into
 * the call as 48 kHz voice-communication audio routed to the telephony uplink.
 * Everything stays on the phone.
 */
object ShellCallAudio {
    const val AUTHORITY = "ai.local.receptionist.callaudio"
    private const val USAGE_CALL_ASSISTANT = 17
    private const val CAPTURE_RATE = 16000
    /** Pocket renders 24 kHz; the HAL's in_call_music profile needs 8/16/32/48 kHz. */
    const val SOURCE_RATE = 24000
    private const val PLAYBACK_RATE = 48000

    @JvmStatic
    fun main(args: Array<String>) {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper()
        log("starting uid=${Process.myUid()}")
        val context = ShellContext.create()
        log("context ready")
        when (args.firstOrNull()) {
            "voice" -> {
                // Test: adb shell ... ShellCallAudio voice mute|unmute|status
                when (args.getOrNull(1)) {
                    "mute" -> muteCall(context, true)
                    "unmute" -> muteCall(context, false)
                }
                val audio = context.getSystemService(AudioManager::class.java)
                log("voice_call muted=${audio.isStreamMute(AudioManager.STREAM_VOICE_CALL)} " +
                    "index=${audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL)}")
                System.exit(0)
            }
            "probe" -> {
                probe(context, File(args.getOrElse(1) { "/data/local/tmp" }), args.getOrNull(2))
                log("probe done")
                System.exit(0)
            }
            else -> bridge(context)
        }
    }

    /** True while the assistant handles a call: the phone's own in-call output is silenced. */
    @Volatile private var callMuted = false

    /**
     * Silences the phone's own in-call output (earpiece/speaker) while the
     * assistant handles a call. AudioService keeps the voice-call stream at
     * index 1 or above and will not mute it, so the helper (shell user, which
     * holds MODIFY_AUDIO_SETTINGS) sets the audio policy's voice-call index to
     * 0, muted, for the phone's own outputs. The call itself is unaffected:
     * the helper reads the downlink digitally and plays into the uplink.
     */
    private fun muteCall(context: Context, mute: Boolean) {
        callMuted = mute
        val audio = context.getSystemService(AudioManager::class.java)
        val stream = AudioManager.STREAM_VOICE_CALL
        val index = if (mute) 0 else audio.getStreamVolume(stream)
        val results = OUTPUT_DEVICES.map { setPolicyVolume(stream, index, mute, it) }
        log("voice call ${if (mute) "silenced" else "restored to $index"} status=$results")
    }

    /** Earpiece, speaker, wired headset/headphones, Bluetooth SCO and A2DP
     *  (audio.h AUDIO_DEVICE_OUT_*). Not the policy's default device: that index
     *  also governs the telephony uplink the assistant speaks into. */
    private val OUTPUT_DEVICES = listOf(0x1, 0x2, 0x4, 0x8, 0x10, 0x80)

    private fun setPolicyVolume(stream: Int, index: Int, muted: Boolean, device: Int): Int = runCatching {
        Class.forName("android.media.AudioSystem")
            .getMethod("setStreamVolumeIndexAS", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
                Boolean::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            .invoke(null, stream, index, muted, device) as Int
    }.getOrElse { log("setStreamVolumeIndexAS failed: ${it.javaClass.simpleName}: ${it.message}"); -1 }

    private fun log(message: String) { println("[ShellCallAudio] $message"); System.out.flush() }

    // ------------------------------------------------------------------ audio

    @SuppressLint("MissingPermission")
    fun createRecord(context: Context, source: Int): AudioRecord {
        val format = AudioFormat.Builder()
            .setSampleRate(CAPTURE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .build()
        return AudioRecord.Builder()
            .setContext(context)
            .setAudioSource(source)
            .setAudioFormat(format)
            .setBufferSizeInBytes(CAPTURE_RATE * 2)
            .build()
    }

    fun createTrack(usage: Int): AudioTrack {
        val builder = AudioAttributes.Builder().setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        if (usage == USAGE_CALL_ASSISTANT) {
            // System usage; setSystemUsage is @SystemApi but available to this process.
            AudioAttributes.Builder::class.java.getMethod("setSystemUsage", Int::class.javaPrimitiveType)
                .invoke(builder, usage)
        } else builder.setUsage(usage)
        return AudioTrack.Builder()
            .setAudioAttributes(builder.build())
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(PLAYBACK_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build())
            .setBufferSizeInBytes(PLAYBACK_RATE * 2 / 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
    }

    /** 24 kHz → 48 kHz PCM16 by linear interpolation. */
    fun upsample(input: ByteArray, length: Int = input.size): ByteArray {
        val samples = length / 2
        val out = ByteArray(samples * 4)
        fun at(i: Int): Int = (input[2 * i].toInt() and 0xff) or (input[2 * i + 1].toInt() shl 8)
        for (i in 0 until samples) {
            val a = at(i)
            val b = if (i + 1 < samples) at(i + 1) else a
            val mid = (a + b) / 2
            out[4 * i] = a.toByte(); out[4 * i + 1] = (a shr 8).toByte()
            out[4 * i + 2] = mid.toByte(); out[4 * i + 3] = (mid shr 8).toByte()
        }
        return out
    }

    /** `<usage>` or `<usage>_tx` (explicitly routed to the telephony uplink device). */
    fun openPlayback(context: Context, spec: String): AudioTrack {
        val routed = spec.endsWith("_tx")
        val track = createTrack(usageFor(spec.removeSuffix("_tx")))
        if (routed) telephonyDevice(context, true)?.let { track.setPreferredDevice(it) }
        log("playback usage=$spec routed=${track.routedDevice?.type}")
        return track
    }

    fun sourceFor(name: String): Int = when (name) {
        "voice_call" -> MediaRecorder.AudioSource.VOICE_CALL
        "voice_uplink" -> MediaRecorder.AudioSource.VOICE_UPLINK
        "voice_recognition" -> MediaRecorder.AudioSource.VOICE_RECOGNITION
        "mic" -> MediaRecorder.AudioSource.MIC
        else -> MediaRecorder.AudioSource.VOICE_DOWNLINK
    }

    fun usageFor(name: String): Int = when (name) {
        "voice_communication" -> AudioAttributes.USAGE_VOICE_COMMUNICATION
        "media" -> AudioAttributes.USAGE_MEDIA
        else -> USAGE_CALL_ASSISTANT
    }

    private fun rmsDb(pcm: ShortArray, count: Int): Double {
        var energy = 0.0
        for (i in 0 until count) { val v = pcm[i] / 32768.0; energy += v * v }
        return 10 * log10((energy / count.coerceAtLeast(1)).coerceAtLeast(1e-12))
    }

    // ------------------------------------------------------------------ probe

    fun telephonyDevice(context: Context, output: Boolean): AudioDeviceInfo? =
        context.getSystemService(AudioManager::class.java)
            .getDevices(if (output) AudioManager.GET_DEVICES_OUTPUTS else AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.type == AudioDeviceInfo.TYPE_TELEPHONY }

    private fun probe(context: Context, directory: File, clips: String?) {
        directory.mkdirs()
        val manager = context.getSystemService(AudioManager::class.java)
        log("mode=${manager.mode}")
        for (device in manager.getDevices(AudioManager.GET_DEVICES_ALL)) {
            log("device id=${device.id} type=${device.type} sink=${device.isSink} name=${device.productName} addr=${device.address}")
        }
        val rx = telephonyDevice(context, false)
        val tx = telephonyDevice(context, true)
        log("telephony rx=${rx?.id} tx=${tx?.id}")
        val captures = listOf("voice_downlink" to null, "voice_downlink" to rx, "voice_call" to rx,
            "voice_recognition" to rx, "mic" to rx)
        for ((name, device) in captures) {
            val label = name + if (device != null) "+rx" else ""
            try {
                val record = createRecord(context, sourceFor(name))
                if (device != null) log("capture $label preferred=${record.setPreferredDevice(device)}")
                val pcm = ShortArray(CAPTURE_RATE * 4)
                record.startRecording()
                var offset = 0
                val deadline = System.currentTimeMillis() + 4500
                while (offset < pcm.size && System.currentTimeMillis() < deadline) {
                    val n = record.read(pcm, offset, minOf(1600, pcm.size - offset), AudioRecord.READ_NON_BLOCKING)
                    if (n < 0) { log("capture $label: read error $n"); break }
                    if (n == 0) { Thread.sleep(20); continue }
                    offset += n
                }
                val routed = record.routedDevice
                record.stop(); record.release()
                writeWav(File(directory, "shell-$label.wav"), pcm, offset, CAPTURE_RATE)
                log("capture $label routed=${routed?.type} samples=$offset rmsDb=${"%.1f".format(rmsDb(pcm, offset))}")
            } catch (failure: Throwable) {
                log("capture $label failed: ${failure.javaClass.simpleName}: ${failure.message}")
            }
        }
        if (clips == null) return
        val plays = listOf("media" to tx, "voice_communication" to tx, "call_assistant" to tx, "media" to null)
        for ((index, entry) in plays.withIndex()) {
            val (name, device) = entry
            val label = name + if (device != null) "+tx" else ""
            val file = File("$clips-${index + 1}.wav")
            try {
                val bytes = upsample(file.readBytes().let { it.copyOfRange(44, it.size) })
                val track = createTrack(usageFor(name))
                if (device != null) log("play $label preferred=${track.setPreferredDevice(device)}")
                track.play()
                track.write(bytes, 0, bytes.size)
                Thread.sleep(bytes.size / 96L + 300)
                log("played clip ${index + 1} $label routed=${track.routedDevice?.type}")
                track.stop(); track.release()
                Thread.sleep(2000)
            } catch (failure: Throwable) {
                log("play $label failed: ${failure.javaClass.simpleName}: ${failure.message}")
            }
        }
    }

    // ----------------------------------------------------------------- bridge

    // ----------------------------------------------------------- provider IPC

    private class Provider(private val context: Context) {
        private var provider: Any? = null
        private var callMethod: java.lang.reflect.Method? = null

        @SuppressLint("PrivateApi", "DiscouragedPrivateApi")
        private fun acquire(): Any {
            provider?.let { return it }
            val manager = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null)!!
            val get = manager.javaClass.getMethod("getContentProviderExternal",
                String::class.java, Int::class.javaPrimitiveType, android.os.IBinder::class.java, String::class.java)
            val holder = get.invoke(manager, AUTHORITY, 0, android.os.Binder(), "receptionist-call-audio")
                ?: throw IllegalStateException("provider unavailable")
            val acquired = holder.javaClass.getField("provider").get(holder)
                ?: throw IllegalStateException("provider not published")
            callMethod = acquired.javaClass.getMethod("call", AttributionSource::class.java, String::class.java,
                String::class.java, String::class.java, android.os.Bundle::class.java)
            provider = acquired
            return acquired
        }

        fun exchange(extras: android.os.Bundle): android.os.Bundle? = try {
            val target = acquire()
            callMethod!!.invoke(target, context.attributionSource, AUTHORITY, "exchange", null, extras) as android.os.Bundle?
        } catch (failure: Throwable) {
            provider = null  // app restarted or not running; reacquire next time
            null
        }
    }

    private fun bridge(context: Context) {
        log("bridge starting uid=${Process.myUid()}")
        val provider = Provider(context)
        val toPlay = java.util.concurrent.LinkedBlockingQueue<ByteArray>()
        var usage = "voice_communication_tx"
        val flush = AtomicBoolean(false)
        val reset = AtomicBoolean(false)
        // Playback thread: blocking writes into the call keep real-time pacing.
        Thread {
            var track: AudioTrack? = null
            while (true) {
                val chunk = toPlay.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
                if (reset.getAndSet(false)) { track?.let { runCatching { it.stop(); it.release() } }; track = null }
                if (flush.getAndSet(false)) track?.let { runCatching { it.pause(); it.flush(); it.play() } }
                if (chunk == null) continue
                try {
                    val current = track ?: openPlayback(context, usage).also { track = it; it.play() }
                    val pcm48 = upsample(chunk)
                    current.write(pcm48, 0, pcm48.size)
                } catch (failure: Throwable) {
                    log("playback failed: ${failure.javaClass.simpleName}: ${failure.message}")
                    track = null
                }
            }
        }.apply { isDaemon = true; start() }

        var record: AudioRecord? = null
        val block = ShortArray(CAPTURE_RATE / 25) // 40 ms
        val bytes = ByteArray(block.size * 2)
        var connected = false
        var lastMute = 0L
        var event: String? = """hello uid=${Process.myUid()}"""
        while (true) {
            val extras = android.os.Bundle()
            val active = record
            if (active != null) {
                var offset = 0
                while (offset < block.size) {
                    val n = active.read(block, offset, block.size - offset)
                    if (n <= 0) break
                    offset += n
                }
                for (i in 0 until offset) {
                    bytes[2 * i] = block[i].toInt().toByte()
                    bytes[2 * i + 1] = (block[i].toInt() shr 8).toByte()
                }
                extras.putByteArray("pcm", bytes.copyOf(offset * 2))
            } else Thread.sleep(40)
            event?.let { extras.putString("event", it) }
            val reply = provider.exchange(extras)
            if (reply == null || reply.getBoolean("not_ready")) {
                if (connected) log("app unavailable")
                connected = false
                record?.let { runCatching { it.stop(); it.release() } }
                record = null
                Thread.sleep(1000)
                continue
            }
            if (!connected) { log("app connected"); connected = true }
            // The audio policy may restore the voice volume on routing changes.
            if (callMuted && System.currentTimeMillis() - lastMute > 2000) {
                OUTPUT_DEVICES.forEach { setPolicyVolume(AudioManager.STREAM_VOICE_CALL, 0, true, it) }
                lastMute = System.currentTimeMillis()
            }
            event = null
            for (command in reply.getStringArrayList("commands") ?: emptyList<String>()) {
                log("command $command")
                when {
                    command.startsWith("capture_start") -> {
                        record?.let { runCatching { it.stop(); it.release() } }
                        val source = command.substringAfter(' ', "voice_downlink")
                        record = try {
                            createRecord(context, sourceFor(source)).also { it.startRecording() }
                        } catch (failure: Throwable) {
                            event = "capture_error ${failure.javaClass.simpleName}"
                            null
                        }
                        if (record != null) event = "capture_started $source"
                    }
                    command == "capture_stop" -> {
                        record?.let { runCatching { it.stop(); it.release() } }
                        record = null
                    }
                    command == "playback_flush" -> { toPlay.clear(); flush.set(true) }
                    command == "mute_call" -> { muteCall(context, true); event = "call_muted" }
                    command == "unmute_call" -> { muteCall(context, false); event = "call_unmuted" }
                    command.startsWith("playback_usage") -> {
                        usage = command.substringAfter(' ', "voice_communication_tx")
                        reset.set(true)
                    }
                }
            }
            reply.getByteArray("play")?.let { toPlay.add(it) }
        }
    }

    private fun writeWav(file: File, pcm: ShortArray, count: Int, rate: Int) {
        RandomAccessFile(file, "rw").use { out ->
            out.setLength(0)
            val data = count * 2
            fun i32(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte()))
            fun i16(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
            out.writeBytes("RIFF"); i32(36 + data); out.writeBytes("WAVEfmt ")
            i32(16); i16(1); i16(1); i32(rate); i32(rate * 2); i16(2); i16(16)
            out.writeBytes("data"); i32(data)
            val bytes = ByteArray(data)
            for (i in 0 until count) { bytes[2 * i] = pcm[i].toInt().toByte(); bytes[2 * i + 1] = (pcm[i].toInt() shr 8).toByte() }
            out.write(bytes)
        }
    }
}

/** Identifies this process to the audio framework as the shell package. */
class ShellContext private constructor(base: Context) : ContextWrapper(base) {
    companion object {
        private const val SHELL = "com.android.shell"

        @SuppressLint("PrivateApi", "DiscouragedPrivateApi")
        fun create(): ShellContext {
            val threadClass = Class.forName("android.app.ActivityThread")
            val constructor = threadClass.getDeclaredConstructor().apply { isAccessible = true }
            val thread = constructor.newInstance()
            threadClass.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
            threadClass.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(thread, true)
            fillConfigurationController(threadClass, thread)
            val system = threadClass.getDeclaredMethod("getSystemContext").invoke(thread) as Context
            return ShellContext(system)
        }

        /** Some builds (e.g. Samsung on Android 16) read the configuration while
         *  creating the system context; a bare ActivityThread has no controller. */
        private fun fillConfigurationController(threadClass: Class<*>, thread: Any) {
            runCatching {
                val field = threadClass.getDeclaredField("mConfigurationController").apply { isAccessible = true }
                if (field.get(thread) != null) return
                val controllerClass = Class.forName("android.app.ConfigurationController")
                val internal = Class.forName("android.app.ActivityThreadInternal")
                val controller = controllerClass.getDeclaredConstructor(internal)
                    .apply { isAccessible = true }.newInstance(thread)
                field.set(thread, controller)
            }.onFailure { System.err.println("[ShellCallAudio] no configuration controller: ${it.message}") }
        }
    }

    override fun getPackageName(): String = SHELL
    override fun getOpPackageName(): String = SHELL
    override fun getAttributionSource(): AttributionSource =
        AttributionSource.Builder(Process.SHELL_UID).setPackageName(SHELL).build()
    override fun getApplicationContext(): Context = this
}
