package ai.local.receptionist.engine

/** Receives UTF-8 token text from native generation. Kept by name for JNI. */
class TokenSink(private val emit: (String) -> Unit) {
    @Suppress("unused")
    fun onToken(bytes: ByteArray) = emit(bytes.toString(Charsets.UTF_8))
}

/**
 * One resident model and context (Gemma, or a small decision model). Calls
 * other than [cancel] must come from a single worker thread per engine.
 */
class LlmEngine {
    companion object { init { System.loadLibrary("receptionist_llm") } }

    @Volatile private var handle = 0L
    @Volatile var loadedPath: String? = null
        private set

    private external fun nativeLoad(path: String, context: Int, threads: Int): Long
    private external fun nativeUnload(handle: Long)
    private external fun nativeCancel(handle: Long)
    private external fun nativePrefill(handle: Long, prompt: ByteArray, staticPrefix: ByteArray): Int
    private external fun nativeDecide(handle: Long, prompt: ByteArray, staticPrefix: ByteArray,
                                      options: Array<ByteArray>): FloatArray?
    private external fun nativeGenerate(handle: Long, prompt: ByteArray, staticPrefix: ByteArray, grammar: String,
                                        maxTokens: Int, temperature: Float, sink: TokenSink?): ByteArray?

    fun load(path: String, context: Int, threads: Int) {
        unload()
        handle = nativeLoad(path, context, threads)
        check(handle != 0L) { "Model failed to load" }
        loadedPath = path
    }

    fun unload() {
        if (handle != 0L) nativeUnload(handle)
        handle = 0L
        loadedPath = null
    }

    fun cancel() { if (handle != 0L) nativeCancel(handle) }

    fun prefill(prompt: String, staticPrefix: String = ""): Int =
        nativePrefill(handle, prompt.toByteArray(), staticPrefix.toByteArray())

    /** Normalised log-probabilities per option, plus elapsed milliseconds. */
    data class Decision(val logProbs: List<Double>, val elapsedMs: Long)

    fun decide(prompt: String, staticPrefix: String, options: List<String>): Decision {
        val raw = nativeDecide(handle, prompt.toByteArray(), staticPrefix.toByteArray(),
            options.map { it.toByteArray() }.toTypedArray()) ?: error("Decision failed")
        return Decision(raw.dropLast(1).map { it.toDouble() }, raw.last().toLong())
    }

    fun generate(prompt: String, grammar: String, maxTokens: Int, temperature: Float,
                 onToken: ((String) -> Unit)?, staticPrefix: String = ""): String {
        val bytes = nativeGenerate(handle, prompt.toByteArray(), staticPrefix.toByteArray(), grammar, maxTokens,
            temperature, onToken?.let { TokenSink(it) })
        return bytes?.toString(Charsets.UTF_8) ?: ""
    }
}
