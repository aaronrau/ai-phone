package ai.local.receptionist.engine

/** Pocket TTS renderer: 24 kHz mono PCM16 frames, delivered as they are produced. */
class PocketTts(directory: String) {
    companion object {
        const val SAMPLE_RATE = 24000
        init { System.loadLibrary("receptionist_pocket") }
    }

    private var handle: Long = nativeCreate(directory)
    @Volatile private var sink: ((ByteArray) -> Unit)? = null

    private external fun nativeCreate(directory: String): Long
    private external fun nativeReset(handle: Long)
    private external fun nativeCancel(handle: Long)
    private external fun nativeDestroy(handle: Long)
    private external fun nativeWarm(handle: Long, voice: String): Int
    private external fun nativeRender(handle: Long, text: String, voice: String): Boolean

    @Suppress("unused")
    fun onFrame(frame: ByteArray) { sink?.invoke(frame) }

    fun warm(voice: String) = nativeWarm(handle, voice)

    /** Blocks until rendered. Returns false when cancelled. */
    fun render(text: String, voice: String, onFrame: (ByteArray) -> Unit): Boolean {
        nativeReset(handle)
        sink = onFrame
        try { return nativeRender(handle, text, voice) } finally { sink = null }
    }

    fun cancel() { if (handle != 0L) nativeCancel(handle) }

    fun close() { if (handle != 0L) { nativeDestroy(handle); handle = 0 } }
}
