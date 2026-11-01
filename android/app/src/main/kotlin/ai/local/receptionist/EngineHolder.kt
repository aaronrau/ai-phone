package ai.local.receptionist

import android.content.Context
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * One process-wide Flutter engine. The service starts it headless; the
 * activity attaches its UI to the same engine, so calls and texts are handled
 * identically whether or not the screen is open.
 */
object EngineHolder {
    const val ENGINE_ID = "receptionist"
    @Volatile private var engine: FlutterEngine? = null
    lateinit var bridge: NativeBridge
        private set

    fun ensure(context: Context): FlutterEngine {
        engine?.let { return it }
        check(Looper.myLooper() == Looper.getMainLooper()) { "Engine must start on the main thread" }
        val app = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(app)
        loader.ensureInitializationComplete(app, null)
        val created = FlutterEngine(app)
        bridge = NativeBridge(app, created.dartExecutor.binaryMessenger)
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, created)
        engine = created
        return created
    }
}
