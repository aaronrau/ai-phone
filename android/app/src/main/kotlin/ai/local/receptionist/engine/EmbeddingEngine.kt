package ai.local.receptionist.engine

/**
 * A small sentence-embedding model (llama.cpp, on the phone's CPU) used to
 * match what callers say against configured topics and intents.
 */
class EmbeddingEngine {
    companion object { init { System.loadLibrary("receptionist_llm") } }

    @Volatile var loadedPath: String? = null
        private set
    @Volatile var dimensions = 0
        private set

    private external fun nativeLoad(path: String, threads: Int): Int
    private external fun nativeUnload()
    private external fun nativeEmbed(text: ByteArray): FloatArray?

    fun load(path: String, threads: Int) {
        if (loadedPath == path) return
        dimensions = nativeLoad(path, threads)
        check(dimensions > 0) { "Embedding model failed to load" }
        loadedPath = path
    }

    fun unload() {
        nativeUnload()
        loadedPath = null
        dimensions = 0
    }

    /** L2-normalised embedding; cosine similarity is a dot product. */
    fun embed(text: String): FloatArray = nativeEmbed(text.toByteArray()) ?: error("Embedding failed")
}
