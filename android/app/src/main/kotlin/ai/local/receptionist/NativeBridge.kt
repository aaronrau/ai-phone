package ai.local.receptionist

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.telecom.TelecomManager
import android.util.Log
import ai.local.receptionist.device.DeviceData
import ai.local.receptionist.engine.CaptureSources
import ai.local.receptionist.engine.EmbeddingEngine
import ai.local.receptionist.engine.LlmEngine
import ai.local.receptionist.engine.PlaybackUsages
import ai.local.receptionist.engine.PocketTts
import ai.local.receptionist.engine.SpeechInput
import ai.local.receptionist.engine.SpeechOutput
import ai.local.receptionist.sms.SmsNotifications
import ai.local.receptionist.sms.SmsStore
import ai.local.receptionist.telephony.CallAudioBridge
import ai.local.receptionist.telephony.CallAudioProbe
import ai.local.receptionist.telephony.CallNotifications
import ai.local.receptionist.telephony.CallRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * The single Dart ⇄ Android boundary. Dart owns policy, prompts, tools and
 * conversation state; Android owns telephony, audio and the native models.
 */
class NativeBridge(private val context: Context, messenger: BinaryMessenger) {
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "receptionist/native")
    private val events = EventChannel(messenger, "receptionist/events")
    private var sink: EventChannel.EventSink? = null
    private val backlog = ArrayDeque<Map<String, Any?>>()
    private val llmWorker = Executors.newSingleThreadExecutor { Thread(it, "llm") }
    private val decisionWorker = Executors.newSingleThreadExecutor { Thread(it, "decision") }
    private val decisionEngine = LlmEngine()
    private val ioWorker = Executors.newSingleThreadExecutor { Thread(it, "models") }
    private val embeddingWorker = Executors.newSingleThreadExecutor { Thread(it, "embedding") }
    private val embedder = EmbeddingEngine()
    private val screeningRequests = ConcurrentHashMap<String, (String) -> Unit>()
    private val screeningIds = AtomicInteger(0)

    @Volatile var activity: Activity? = null
    private var llm: LlmEngine? = null
    @Volatile private var tts: PocketTts? = null
    @Volatile private var input: SpeechInput? = null
    val output = SpeechOutput { emit(it) }
    val callAudio = CallAudioBridge { emit(it) }
    /** Keeps the phone microphone out of assistant calls (see MicGate). */
    private val micGate = ai.local.receptionist.telephony.MicGate({ output.sounding }, { output.bridgeSink != null })
    @Volatile private var listeningToBridge = false

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                while (backlog.isNotEmpty()) events.success(backlog.removeFirst())
            }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        methods.setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun emit(event: Map<String, Any?>) {
        val post = Runnable {
            val target = sink
            if (target != null) target.success(event)
            else {
                if (backlog.size >= 500) backlog.removeFirst()
                backlog.addLast(event)
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) post.run() else main.post(post)
    }

    fun requestScreening(number: String, presentation: Int, respond: (String) -> Unit) {
        val id = "screen-${screeningIds.incrementAndGet()}"
        screeningRequests[id] = respond
        main.postDelayed({ screeningRequests.remove(id) }, 10_000)
        emit(mapOf("type" to "screen_call", "requestId" to id, "number" to number,
            "presentation" to presentation))
    }

    /** Provisioned by tool/provision_models.py through the app identity. */
    val modelDirectory: File
        get() = File(context.filesDir, "models")

    private fun <T> background(executor: java.util.concurrent.Executor, result: MethodChannel.Result, block: () -> T) {
        executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (failure: Throwable) {
                Log.e("NativeBridge", "native call failed", failure)
                main.post { result.error("NATIVE", failure.message ?: failure.javaClass.simpleName, null) }
            }
        }
    }

    private fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun roleHeld(role: String): Boolean =
        context.getSystemService(RoleManager::class.java).isRoleHeld(role)


    private val permissions = listOf(
        Manifest.permission.RECORD_AUDIO, Manifest.permission.READ_CONTACTS,
        Manifest.permission.READ_CALENDAR, Manifest.permission.RECEIVE_SMS,
        Manifest.permission.SEND_SMS, Manifest.permission.READ_SMS, Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.ANSWER_PHONE_CALLS, Manifest.permission.CALL_PHONE,
        Manifest.permission.POST_NOTIFICATIONS,
    )

    private fun status(): Map<String, Any?> {
        val models = modelDirectory
        return mapOf(
            "modelsDir" to models.path,
            "filesDir" to context.filesDir.path,
            "gemma" to (models.listFiles()?.filter { it.name.endsWith(".gguf") }?.map { it.name } ?: emptyList<String>()),
            "whisper" to File(models, "whisper").isDirectory,
            "parakeet" to (File(models, "parakeet-0.6b").isDirectory || File(models, "parakeet-110m").isDirectory),
            "pocket" to File(models, "pocket").isDirectory,
            "vad" to File(models, "vad/silero_vad.onnx").isFile,
            "llmLoaded" to (llm?.loadedPath != null),
            "decisionModel" to decisionEngine.loadedPath?.substringAfterLast('/'),
            "decisionModels" to (File(models, "decision").listFiles()?.filter { it.name.endsWith(".gguf") }
                ?.map { it.name } ?: emptyList<String>()),
            "ttsLoaded" to (tts != null),
            "sttLoaded" to (input != null),
            "sttModel" to input?.modelName,
            "dialerRole" to roleHeld(RoleManager.ROLE_DIALER),
            "screeningRole" to roleHeld(RoleManager.ROLE_CALL_SCREENING),
            "smsRole" to roleHeld(RoleManager.ROLE_SMS),
            "batteryExempt" to context.getSystemService(PowerManager::class.java)
                .isIgnoringBatteryOptimizations(context.packageName),
            "overlayAllowed" to Settings.canDrawOverlays(context),
            "permissions" to permissions.associateWith { granted(it) },
            "listening" to (input?.listening == true),
            "callAudioHelper" to callAudio.connected,
            "helperSetup" to ai.local.receptionist.adb.HelperLauncher.status(context),
            "calls" to CallRegistry.all().map { (id, call) -> CallRegistry.describe(id, call) },
            "callAudio" to CallRegistry.audioState(),
            "callScreeningModeSupported" to context.getSystemService(AudioManager::class.java).isCallScreeningModeSupported,
        )
    }

    private fun loadModels(call: MethodCall): Map<String, Any?> {
        val dir = modelDirectory
        val voice = call.argument<String>("voice") ?: "british_female"
        val timings = LinkedHashMap<String, Any?>()
        if (tts == null) {
            val start = System.currentTimeMillis()
            emit(mapOf("type" to "models", "stage" to "speech"))
            val created = PocketTts(File(dir, "pocket").path)
            created.warm(voice)
            tts = created
            output.tts = created
            timings["ttsMs"] = System.currentTimeMillis() - start
        }
        val sttModel = call.argument<String>("stt") ?: "parakeet-0.6b"
        if (input == null || input?.modelName != sttModel) {
            val start = System.currentTimeMillis()
            emit(mapOf("type" to "models", "stage" to "listening"))
            input?.stop()
            input = SpeechInput(dir, sttModel, { emit(it) }, { output.active })
            timings["sttMs"] = System.currentTimeMillis() - start
            timings["stt"] = input?.modelName
        }
        val gemma = call.argument<String>("llm")
        if (!gemma.isNullOrBlank()) {
            val path = if (gemma.startsWith("/")) gemma else File(dir, gemma).path
            val engine = llm ?: LlmEngine().also { llm = it }
            if (engine.loadedPath != path) {
                val start = System.currentTimeMillis()
                emit(mapOf("type" to "models", "stage" to "gemma"))
                // Loading must not race a generation on the LLM worker.
                llmWorker.submit {
                    engine.load(path, call.argument<Int>("context") ?: 4096, call.argument<Int>("threads") ?: 4)
                }.get()
                timings["llmMs"] = System.currentTimeMillis() - start
            }
        }
        emit(mapOf("type" to "models", "stage" to "ready"))
        return timings
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(status())
                "loadModels" -> background(ioWorker, result) { loadModels(call) }
                "llmPrefill" -> {
                    val engine = llm ?: return result.error("NOT_READY", "Gemma not loaded", null)
                    val prompt = call.argument<String>("prompt")!!
                    background(llmWorker, result) { engine.prefill(prompt) }
                }
                "llmGenerate" -> {
                    val engine = llm ?: return result.error("NOT_READY", "Gemma not loaded", null)
                    val id = call.argument<String>("id") ?: ""
                    val prompt = call.argument<String>("prompt")!!
                    val grammar = call.argument<String>("grammar") ?: ""
                    val maxTokens = call.argument<Int>("maxTokens") ?: 200
                    val temperature = (call.argument<Double>("temperature") ?: 0.4).toFloat()
                    background(llmWorker, result) {
                        engine.generate(prompt, grammar, maxTokens, temperature, onToken = { text ->
                            emit(mapOf("type" to "token", "id" to id, "text" to text))
                        })
                    }
                }
                "llmCancel" -> { llm?.cancel(); result.success(null) }
                "llmUnload" -> background(llmWorker, result) { llm?.unload(); null }
                "decisionLoad" -> {
                    val name = call.argument<String>("model")!!
                    val path = if (name.startsWith("/")) name else File(modelDirectory, "decision/$name").path
                    background(decisionWorker, result) {
                        if (decisionEngine.loadedPath != path) {
                            decisionEngine.load(path, call.argument<Int>("context") ?: 2048, call.argument<Int>("threads") ?: 4)
                        }
                        path.substringAfterLast('/')
                    }
                }
                "decisionUnload" -> background(decisionWorker, result) { decisionEngine.unload(); null }
                "embedLoad" -> {
                    val name = call.argument<String>("model")!!
                    val path = if (name.startsWith("/")) name else File(modelDirectory, "embedding/$name").path
                    background(embeddingWorker, result) {
                        require(File(path).isFile) { "Embedding model not installed" }
                        embedder.load(path, call.argument<Int>("threads") ?: 4)
                        embedder.dimensions
                    }
                }
                "embed" -> background(embeddingWorker, result) {
                    // One or more texts in, one normalised vector each out.
                    val texts = call.argument<List<String>>("texts") ?: emptyList()
                    texts.map { text -> embedder.embed(text).map { it.toDouble() } }
                }
                "decide" -> {
                    // engine: "decision" (small model) or "main" (Gemma)
                    val main = call.argument<String>("engine") == "main"
                    val target = if (main) llm else decisionEngine
                    if (target?.loadedPath == null) return result.error("NOT_READY", "Model not loaded", null)
                    val prompt = call.argument<String>("prompt")!!
                    val prefix = call.argument<String>("staticPrefix") ?: ""
                    val options = call.argument<List<String>>("options")!!
                    background(if (main) llmWorker else decisionWorker, result) {
                        val decision = target.decide(prompt, prefix, options)
                        mapOf("logProbs" to decision.logProbs, "ms" to decision.elapsedMs)
                    }
                }
                "decisionGenerate" -> {
                    if (decisionEngine.loadedPath == null) return result.error("NOT_READY", "Model not loaded", null)
                    val prompt = call.argument<String>("prompt")!!
                    val prefix = call.argument<String>("staticPrefix") ?: ""
                    val grammar = call.argument<String>("grammar") ?: ""
                    val maxTokens = call.argument<Int>("maxTokens") ?: 64
                    background(decisionWorker, result) {
                        decisionEngine.generate(prompt, grammar, maxTokens, 0f, null, prefix)
                    }
                }
                "speechPrerender" -> {
                    output.cacheDirectory = File(context.cacheDir, "speech")
                    val voice = call.argument<String>("voice") ?: "british_female"
                    for (text in call.argument<List<String>>("texts") ?: emptyList()) output.prerender(text, voice)
                    result.success(null)
                }
                "speak" -> {
                    output.cacheDirectory = File(context.cacheDir, "speech")
                    output.speak(call.argument<String>("id")!!, call.argument<String>("text")!!,
                        call.argument<String>("voice") ?: "british_female", call.argument<Boolean>("cache") == true)
                    result.success(null)
                }
                "stopSpeaking" -> {
                    output.stop()
                    if (output.bridgeSink != null) callAudio.flushPlayback()
                    result.success(null)
                }
                "ttsBench" -> {
                    // Debug: render without playing, on a fresh thread like the speech worker.
                    val engine = output.tts ?: return result.error("NOT_READY", "Speech model not loaded", null)
                    val text = call.argument<String>("text")!!
                    val voice = call.argument<String>("voice") ?: "british_female"
                    Thread {
                        val start = android.os.SystemClock.elapsedRealtime()
                        var first = -1L
                        var samples = 0L
                        val outcome = runCatching {
                            engine.render(text, voice) { frame ->
                                if (first < 0) first = android.os.SystemClock.elapsedRealtime() - start
                                samples += frame.size / 2
                            }
                        }
                        val map = mapOf("renderMs" to (android.os.SystemClock.elapsedRealtime() - start),
                            "firstFrameMs" to first, "audioMs" to samples * 1000 / PocketTts.SAMPLE_RATE,
                            "error" to outcome.exceptionOrNull()?.message)
                        android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(map) }
                    }.start()
                }
                "helperCommand" -> {
                    callAudio.command(call.argument<String>("command")!!)
                    result.success(null)
                }
                "holdMusic" -> {
                    output.holdMusic = call.argument<Boolean>("on") == true
                    result.success(null)
                }
                "setPlayback" -> {
                    val usage = call.argument<String>("usage")
                    if (usage == "call_bridge") {
                        output.bridgeSink = { frame -> callAudio.play(frame) }
                    } else {
                        output.bridgeSink = null
                        usage?.let { output.usage = PlaybackUsages.parse(it) }
                    }
                    call.argument<Double>("gain")?.let { output.gain = it.toFloat() }
                    result.success(null)
                }
                "listenStart" -> {
                    val speech = input ?: return result.error("NOT_READY", "Speech models not loaded", null)
                    call.argument<Double>("endSilence")?.let { speech.endSilenceSeconds = it.toFloat() }
                    val session = call.argument<String>("session") ?: "session"
                    val source = call.argument<String>("source")
                    if (source == "call_bridge") {
                        if (!callAudio.connected) return result.error("NO_HELPER", "Call audio helper is not running", null)
                        listeningToBridge = true
                        callAudio.startCapture("voice_downlink")
                        speech.startFeed({ timeout -> callAudio.read(timeout) }, session)
                    } else {
                        listeningToBridge = false
                        speech.start(CaptureSources.parse(source), session)
                    }
                    result.success(null)
                }
                "listenStop" -> background(ioWorker, result) {
                    input?.stop()
                    if (listeningToBridge) { callAudio.stopCapture(); listeningToBridge = false }
                    null
                }
                "callAnswer" -> { CallRegistry.answer(call.argument<String>("callId")!!); result.success(null) }
                "callHold" -> { CallRegistry.hold(call.argument<String>("callId")!!); result.success(null) }
                "callUnhold" -> { CallRegistry.unhold(call.argument<String>("callId")!!); result.success(null) }
                "callReject" -> { CallRegistry.reject(call.argument<String>("callId")!!); result.success(null) }
                "callHangup" -> { CallRegistry.hangup(call.argument<String>("callId")!!); result.success(null) }
                "callSpeaker" -> { CallRegistry.setSpeaker(call.argument<Boolean>("on") == true); result.success(null) }
                "callMute" -> {
                    micGate.want(call.argument<Boolean>("on") == true, call.argument<String>("mode"))
                    result.success(null)
                }
                "callDtmf" -> {
                    CallRegistry.dtmf(call.argument<String>("callId")!!, call.argument<String>("digit")!!.first())
                    result.success(null)
                }
                "callQuiet" -> {
                    // While the assistant handles a call, keep the phone itself silent:
                    // in-call volume to its minimum (Android does not allow 0), restored after.
                    val audio = context.getSystemService(AudioManager::class.java)
                    val prefs = context.getSharedPreferences("receptionist", Context.MODE_PRIVATE)
                    val stream = AudioManager.STREAM_VOICE_CALL
                    // The call-audio helper (shell user) can mute the stream outright.
                    callAudio.command(if (call.argument<Boolean>("on") == true) "mute_call" else "unmute_call")
                    runCatching {
                        if (call.argument<Boolean>("on") == true) {
                            if (!prefs.contains("saved_call_volume")) {
                                prefs.edit().putInt("saved_call_volume", audio.getStreamVolume(stream)).commit()
                            }
                            audio.setStreamVolume(stream, audio.getStreamMinVolume(stream), 0)
                        } else if (prefs.contains("saved_call_volume")) {
                            audio.setStreamVolume(stream, prefs.getInt("saved_call_volume", audio.getStreamMaxVolume(stream) / 2), 0)
                            prefs.edit().remove("saved_call_volume").commit()
                        }
                    }.onFailure { Log.w("NativeBridge", "call volume change failed: ${it.message}") }
                    result.success(null)
                }
                "enterCallMode" -> {
                    ReceptionistService.enterCallMode(context)
                    ai.local.receptionist.telephony.CallCpuWindow.show(context)
                    result.success(null)
                }
                "leaveCallMode" -> {
                    ReceptionistService.leaveCallMode(context)
                    ai.local.receptionist.telephony.CallCpuWindow.hide(context)
                    result.success(null)
                }
                "markAiNumber" -> {
                    CallRegistry.markAiNumber(call.argument<String>("number") ?: "")
                    result.success(null)
                }
                "aiCallNotification" -> {
                    val id = call.argument<String>("callId") ?: ""
                    CallRegistry.markAiCall(id)
                    CallNotifications.setAi(context, id, call.argument<String>("title") ?: "AI assistant is answering",
                        call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "transferRequest" -> {
                    CallNotifications.showTransfer(context, call.argument<String>("callId") ?: "",
                        call.argument<String>("title") ?: "A contact is calling", call.argument<String>("body") ?: "")
                    result.success(null)
                }
                "callNotification" -> {
                    // After "Take over": the call becomes the owner's, shown as a normal call notification.
                    val id = call.argument<String>("callId") ?: ""
                    CallRegistry.get(id)?.let { CallRegistry.unmarkAi(id, it) }
                    CallNotifications.refresh(context)
                    result.success(null)
                }
                "placeCall" -> {
                    val telecom = context.getSystemService(TelecomManager::class.java)
                    telecom.placeCall(Uri.fromParts("tel", call.argument<String>("number")!!, null), null)
                    result.success(null)
                }
                "screenDecision" -> {
                    val decision = call.argument<String>("decision") ?: "allow"
                    if (decision == "silence") call.argument<String>("number")?.let { CallRegistry.markAiNumber(it) }
                    screeningRequests.remove(call.argument<String>("requestId"))?.invoke(decision)
                    result.success(null)
                }
                "probeCallAudio" -> {
                    val speech = input ?: return result.error("NOT_READY", "Speech models not loaded", null)
                    val voice = call.argument<String>("voice") ?: "british_female"
                    background(ioWorker, result) {
                        speech.stop()
                        CallAudioProbe.run(context, speech, output, voice) { emit(it) }
                    }
                }
                "smsSend" -> background(ioWorker, result) {
                    SmsStore.send(context, call.argument<String>("number")!!, call.argument<String>("text")!!)
                }
                "blockNumber" -> background(ioWorker, result) {
                    val values = android.content.ContentValues().apply {
                        put(android.provider.BlockedNumberContract.BlockedNumbers.COLUMN_ORIGINAL_NUMBER,
                            call.argument<String>("number")!!)
                    }
                    context.contentResolver.insert(android.provider.BlockedNumberContract.BlockedNumbers.CONTENT_URI, values)
                        ?.toString()
                }
                "unblockNumber" -> background(ioWorker, result) {
                    android.provider.BlockedNumberContract.unblock(context, call.argument<String>("number")!!)
                }
                "lookupContact" -> background(ioWorker, result) {
                    DeviceData.lookupContact(context, call.argument<String>("number") ?: "")
                }
                "contacts" -> background(ioWorker, result) { DeviceData.contacts(context) }
                "calendarEvents" -> background(ioWorker, result) {
                    DeviceData.calendarEvents(context, (call.argument<Number>("start")!!).toLong(),
                        (call.argument<Number>("end")!!).toLong())
                }
                "notifyOwner" -> {
                    DeviceData.notifyOwner(context, call.argument<String>("title") ?: "AI Phone",
                        call.argument<String>("body") ?: "", call.argument<Boolean>("urgent") == true)
                    result.success(null)
                }
                "smsThreads" -> background(ioWorker, result) {
                    SmsStore.threads(context, call.argument<Int>("limit") ?: 200)
                }
                "smsMessages" -> background(ioWorker, result) {
                    SmsStore.messages(context, call.argument<Number>("threadId")!!.toLong(), call.argument<Int>("limit") ?: 300)
                }
                "smsThreadFor" -> background(ioWorker, result) {
                    SmsStore.threadFor(context, call.argument<String>("number")!!)
                }
                "smsMarkRead" -> background(ioWorker, result) {
                    val thread = call.argument<Number>("threadId")!!.toLong()
                    SmsStore.markRead(context, thread)
                    SmsNotifications.clear(context, thread)
                    null
                }
                "smsDeleteThread" -> background(ioWorker, result) {
                    SmsStore.deleteThread(context, call.argument<Number>("threadId")!!.toLong())
                }
                "smsNotify" -> {
                    SmsNotifications.show(context, call.argument<Number>("threadId")?.toLong() ?: -1L,
                        call.argument<String>("title") ?: "New text", call.argument<String>("body") ?: "")
                    result.success(null)
                }
                "mmsPart" -> background(ioWorker, result) {
                    SmsStore.partBytes(context, call.argument<Number>("partId")!!.toLong())
                }
                "requestRole" -> {
                    val host = activity ?: return result.error("NO_UI", "Open the app first", null)
                    val role = when (call.argument<String>("role")) {
                        "screening" -> RoleManager.ROLE_CALL_SCREENING
                        "sms" -> RoleManager.ROLE_SMS
                        else -> RoleManager.ROLE_DIALER
                    }
                    val manager = context.getSystemService(RoleManager::class.java)
                    host.startActivityForResult(manager.createRequestRoleIntent(role), 41)
                    result.success(null)
                }
                "requestPermissions" -> {
                    val host = activity ?: return result.error("NO_UI", "Open the app first", null)
                    host.requestPermissions(permissions.filter { !granted(it) }.toTypedArray(), 42)
                    result.success(null)
                }
                "helperPair" -> { ai.local.receptionist.adb.HelperLauncher.startPairing(activity ?: context); result.success(null) }
                "helperStart" -> { ai.local.receptionist.adb.HelperLauncher.ensureRunning(context, force = true); result.success(null) }
                "requestOverlay" -> {
                    (activity ?: context).startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "requestBatteryExemption" -> {
                    (activity ?: context).startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "log" -> {
                    Log.i("ReceptionistDart", call.argument<String>("message") ?: "")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (failure: Throwable) {
            Log.e("NativeBridge", "method ${call.method} failed", failure)
            result.error("NATIVE", failure.message ?: failure.javaClass.simpleName, null)
        }
    }
}
