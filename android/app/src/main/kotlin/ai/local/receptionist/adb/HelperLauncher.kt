package ai.local.receptionist.adb

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import ai.local.receptionist.EngineHolder
import ai.local.receptionist.MainActivity
import ai.local.receptionist.telephony.CallAudioBridge
import ai.local.receptionist.telephony.CallRegistry
import java.io.File
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Starts the call-audio helper (ShellCallAudio) on the phone itself, with no
 * computer: the app pairs once with Wireless debugging, then connects to its
 * own adbd over the loopback address to run the helper as the shell user.
 *
 * - Pairing is one-time: the owner types the six-digit code from Developer
 *   options → Wireless debugging → Pair device with pairing code into this
 *   app's notification. The app then grants itself WRITE_SECURE_SETTINGS,
 *   keeps USB debugging on (adbd, and with it the helper, keeps running when
 *   Wi-Fi drops) and disables the 7-day adb authorization timeout.
 * - After a reboot, app update or helper crash the app turns Wireless
 *   debugging on (trusted Wi-Fi only), starts the helper and turns it off again.
 */
object HelperLauncher {
    private const val TAG = "HelperLauncher"
    private const val CHANNEL = "helper_setup"
    private const val NOTIFICATION_ID = 1201
    private const val CODE_KEY = "code"
    private const val CONNECT_SERVICE = "_adb-tls-connect._tcp"
    private const val PAIRING_SERVICE = "_adb-tls-pairing._tcp"
    private const val HELPER_CLASS = "ai.local.receptionist.shell.ShellCallAudio"
    private const val LOG = "/data/local/tmp/receptionist-call-audio.log"
    private const val WATCH_MS = 2 * 60_000L

    private val worker = Executors.newSingleThreadExecutor { Thread(it, "adb") }
    private val main = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private val queued = AtomicBoolean(false)
    @Volatile private var message: String? = null
    @Volatile private var pairingPort: Int? = null
    @Volatile private var pairingDiscovery: NsdManager.DiscoveryListener? = null
    @Volatile private var watching = false
    @Volatile private var lastAttempt = 0L
    @Volatile private var failures = 0
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

    private fun keyDir(context: Context) = File(context.noBackupFilesDir, "adb")
    private fun prefs(context: Context) = context.getSharedPreferences("helper", Context.MODE_PRIVATE)
    fun paired(context: Context) = prefs(context).getBoolean("paired", false) && AdbKey.exists(keyDir(context))
    private val helperConnected get() = CallAudioBridge.instance?.connected == true

    fun status(context: Context): Map<String, Any?> = mapOf(
        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S),
        "developerOptions" to (Settings.Global.getInt(context.contentResolver,
            Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1),
        "paired" to paired(context),
        "autoStart" to (context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED),
        "busy" to running.get(),
        "message" to message,
    )

    private fun report(context: Context, text: String, notify: Boolean = false, done: Boolean = false) {
        message = text
        Log.i(TAG, text)
        main.post {
            runCatching { EngineHolder.bridge.emit(mapOf("type" to "helper_setup", "message" to text)) }
            if (notify) postNotification(context, text, askForCode = false, ongoing = !done)
        }
    }

    // ------------------------------------------------------------ pairing

    /** Begins one-time pairing: listens for the pairing service, asks for the code, opens Developer options. */
    fun startPairing(context: Context) {
        val app = context.applicationContext
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            report(app, "Starting the helper on the phone needs Android 12 or later."); return
        }
        pairingPort = null
        discoverPairingService(app)
        postNotification(app, "In Wireless debugging, tap \"Pair device with pairing code\", then enter the " +
            "code here.", askForCode = true, ongoing = true)
        message = "Waiting for the pairing code"
        val settings = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .putExtra(":settings:fragment_args_key", "toggle_adb_wireless")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { app.startActivity(settings) }.onFailure { Log.w(TAG, "developer options: ${it.message}") }
    }

    private fun discoverPairingService(context: Context) {
        val nsd = context.getSystemService(NsdManager::class.java)
        pairingDiscovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        val listener = discover(context, PAIRING_SERVICE) { port -> pairingPort = port }
        pairingDiscovery = listener
        // The pairing dialog lasts a few minutes at most.
        main.postDelayed({ stopPairingDiscovery(context, listener) }, 10 * 60_000L)
    }

    private fun stopPairingDiscovery(context: Context, listener: NsdManager.DiscoveryListener? = pairingDiscovery) {
        if (listener == null) return
        runCatching { context.getSystemService(NsdManager::class.java).stopServiceDiscovery(listener) }
        if (pairingDiscovery === listener) pairingDiscovery = null
    }

    /** Called by [PairingCodeReceiver] with the code the owner typed. */
    fun onPairingCode(context: Context, code: String) {
        val app = context.applicationContext
        val digits = code.filter { it.isDigit() }
        if (digits.length != 6) {
            postNotification(app, "The pairing code has six digits. Try again.", askForCode = true, ongoing = true)
            return
        }
        postNotification(app, "Pairing…", askForCode = false, ongoing = true)
        worker.execute {
            try {
                val deadline = SystemClock.elapsedRealtime() + 15_000
                while (pairingPort == null && SystemClock.elapsedRealtime() < deadline) Thread.sleep(250)
                val port = pairingPort ?: throw IllegalStateException(
                    "No pairing code is showing. Open \"Pair device with pairing code\" and try again.")
                val key = AdbKey.loadOrCreate(keyDir(app))
                AdbClient.pair(port, digits, key)
                prefs(app).edit().putBoolean("paired", true).apply()
                main.post { stopPairingDiscovery(app) }
                report(app, "Paired. Starting the call audio helper…", notify = true)
                start(app, setup = true)
            } catch (failure: AdbClient.PairingException) {
                Log.w(TAG, "pairing failed: ${failure.message}")
                main.post { postNotification(app, "That code did not work (${failure.message}). Enter the code " +
                    "now showing.", askForCode = true, ongoing = true) }
            } catch (failure: Exception) {
                Log.w(TAG, "pairing failed", failure)
                main.post { postNotification(app, failure.message ?: "Pairing failed.", askForCode = true, ongoing = true) }
            }
        }
    }

    // ------------------------------------------------------------ starting

    /**
     * Makes sure the helper runs from this APK. Cheap when it already does;
     * otherwise starts it in the background. Never restarts a helper that is
     * serving a call.
     */
    fun ensureRunning(context: Context, force: Boolean = false) {
        val app = context.applicationContext
        if (!paired(app) || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        watch(app)
        val current = prefs(app).getString("apk", null) == app.applicationInfo.sourceDir
        if (helperConnected && (current || CallRegistry.all().isNotEmpty())) return
        if (!force) {
            // Back off after failures (e.g. untrusted Wi-Fi): 2, 4, 8 … 30 minutes.
            val wait = if (failures == 0) 0L else minOf(30 * 60_000L, WATCH_MS shl (failures - 1))
            if (SystemClock.elapsedRealtime() - lastAttempt < wait) return
        }
        if (!queued.compareAndSet(false, true)) return
        worker.execute {
            try { start(app, setup = false) } finally { queued.set(false) }
        }
    }

    private fun start(context: Context, setup: Boolean) {
        if (!running.compareAndSet(false, true)) return
        // A start queued behind another one: the helper may be up from this APK already.
        if (!setup && helperConnected && prefs(context).getString("apk", null) == context.applicationInfo.sourceDir) {
            running.set(false)
            return
        }
        lastAttempt = SystemClock.elapsedRealtime()
        val resolver = context.contentResolver
        var turnedOnWireless = false
        try {
            val key = AdbKey.loadOrCreate(keyDir(context))
            val canWrite = context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
                PackageManager.PERMISSION_GRANTED
            if (Settings.Global.getInt(resolver, "adb_wifi_enabled", 0) != 1) {
                if (!canWrite) throw IllegalStateException("Turn on Wireless debugging to start the helper.")
                if (!onWifi(context)) {
                    watchWifi(context)
                    throw IllegalStateException("Waiting for Wi-Fi to start the call audio helper.")
                }
                Settings.Global.putInt(resolver, "adb_wifi_enabled", 1)
                turnedOnWireless = true
                // On a Wi-Fi access point not yet allowed, Android asks "Always allow on this
                // network" (dual-band and mesh networks have one per access point).
                report(context, "Starting the call audio helper. If asked, tick \"Always allow on this network\".")
                // The setting reads 1 at first and drops back to 0 a moment later while the
                // prompt shows; it counts as on once it has stayed on for three seconds.
                val deadline = SystemClock.elapsedRealtime() + 120_000
                var onSince = 0L
                while (SystemClock.elapsedRealtime() < deadline) {
                    val now = SystemClock.elapsedRealtime()
                    if (Settings.Global.getInt(resolver, "adb_wifi_enabled", 0) == 1) {
                        if (onSince == 0L) onSince = now
                        if (now - onSince >= 3000) break
                    } else {
                        onSince = 0L
                    }
                    Thread.sleep(250)
                }
                if (Settings.Global.getInt(resolver, "adb_wifi_enabled", 0) != 1) {
                    throw IllegalStateException("Wireless debugging is not allowed on this Wi-Fi access point. " +
                        "Tap Start and tick \"Always allow on this network\" when asked.")
                }
            }
            // Right after Wireless debugging turns on, mDNS can still return the previous
            // session's port, or adbd may not accept yet: look up again until it answers.
            var port = 0
            val portDeadline = SystemClock.elapsedRealtime() + 30_000
            while (port == 0) {
                for (candidate in findPorts(context, CONNECT_SERVICE, 10_000)) {
                    try { AdbClient.shell(candidate, key, "true"); port = candidate; break }
                    catch (failure: java.net.ConnectException) { Log.i(TAG, "port $candidate not answering") }
                }
                if (port != 0) break
                if (SystemClock.elapsedRealtime() > portDeadline) {
                    throw IllegalStateException("Wireless debugging did not come up.")
                }
                Thread.sleep(1000)
            }
            if (setup) {
                AdbClient.shell(port, key,
                    "pm grant ${context.packageName} ${Manifest.permission.WRITE_SECURE_SETTINGS}; " +
                        "settings put global adb_allowed_connection_time 0; " +
                        "settings put global adb_enabled 1")
            }
            val output = AdbClient.shell(port, key, startCommand(context.applicationInfo.sourceDir))
            if (!output.contains("HELPER_OK")) {
                throw IllegalStateException("The helper did not start: ${output.trim().takeLast(300)}")
            }
            prefs(context).edit().putString("apk", context.applicationInfo.sourceDir).apply()
            val connectDeadline = SystemClock.elapsedRealtime() + 10_000
            while (!helperConnected && SystemClock.elapsedRealtime() < connectDeadline) Thread.sleep(200)
            failures = 0
            report(context, if (helperConnected) "Call audio helper running." else
                "Helper started; waiting for it to connect.", notify = setup, done = true)
            if (setup) turnedOnWireless = true // the owner turned it on for pairing; it is no longer needed
        } catch (failure: AdbClient.NotPairedException) {
            // Kept as paired: a dropped connection looks the same as a revoked key.
            failures++
            report(context, "Wireless debugging refused this app. If this keeps happening, set up the helper " +
                "again.", notify = true, done = true)
        } catch (failure: Exception) {
            failures++
            Log.w(TAG, "helper start failed", failure)
            report(context, failure.message ?: failure.javaClass.simpleName, notify = setup, done = true)
        } finally {
            // Keep adbd off the network unless the owner wants it: with USB
            // debugging on, adbd (and the helper inside it) keeps running.
            if (turnedOnWireless && Settings.Global.getInt(resolver, Settings.Global.ADB_ENABLED, 0) == 1 &&
                context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED) {
                runCatching { Settings.Global.putInt(resolver, "adb_wifi_enabled", 0) }
            }
            running.set(false)
            main.post { runCatching { EngineHolder.bridge.emit(mapOf("type" to "helper_setup", "message" to message)) } }
        }
    }

    /** Shell command: replace any helper, start this APK's, wait until it is detached and running. */
    private fun startCommand(apk: String): String {
        // Anchored to the helper's own command line: this shell's command line
        // contains the class name too, and must not match.
        val pattern = "'^app_process .*${HELPER_CLASS.replaceAfterLast('.', "[S]hellCallAudio")}'"
        return "pkill -f $pattern; " +
            "CLASSPATH='$apk' setsid nohup app_process /system/bin $HELPER_CLASS bridge > $LOG 2>&1 < /dev/null & " +
            "for i in \$(seq 1 60); do grep -q 'bridge starting' $LOG && break; sleep 0.25; done; " +
            "sleep 1; pgrep -f $pattern > /dev/null && echo HELPER_OK || { echo HELPER_FAILED; tail -5 $LOG; }"
    }

    // ------------------------------------------------------------ watching

    /** Restarts a helper that died (and refreshes after updates) while the app runs. */
    private fun watch(context: Context) {
        if (watching) return
        watching = true
        val tick = object : Runnable {
            override fun run() {
                if (!helperConnected && CallRegistry.all().isEmpty()) ensureRunning(context)
                main.postDelayed(this, WATCH_MS)
            }
        }
        main.postDelayed(tick, WATCH_MS)
    }

    private fun onWifi(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        return cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
    }

    private fun watchWifi(context: Context) = main.post {
        if (wifiCallback != null) return@post
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.postDelayed({ if (!helperConnected) ensureRunning(context, force = true) }, 5_000)
            }
        }
        wifiCallback = callback
        context.getSystemService(ConnectivityManager::class.java).registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
    }

    // ------------------------------------------------------------ discovery

    private fun localAddresses(): Set<InetAddress> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }.toSet()
    }.getOrDefault(emptySet())

    /** Finds this phone's own adb service of [type] (other phones on the Wi-Fi advertise too). */
    private fun discover(context: Context, type: String, found: (Int) -> Unit): NsdManager.DiscoveryListener {
        val nsd = context.getSystemService(NsdManager::class.java)
        val callbacks = Executors.newSingleThreadExecutor()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) { Log.w(TAG, "discovery failed $errorCode") }
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
            override fun onDiscoveryStarted(serviceType: String?) {}
            override fun onDiscoveryStopped(serviceType: String?) { callbacks.shutdown() }
            override fun onServiceLost(info: NsdServiceInfo?) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    nsd.registerServiceInfoCallback(info, callbacks, object : NsdManager.ServiceInfoCallback {
                        override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                        override fun onServiceLost() {}
                        override fun onServiceInfoCallbackUnregistered() {}
                        override fun onServiceUpdated(resolved: NsdServiceInfo) {
                            runCatching { nsd.unregisterServiceInfoCallback(this) }
                            if (resolved.hostAddresses.any { it in localAddresses() }) found(resolved.port)
                        }
                    })
                } else {
                    @Suppress("DEPRECATION")
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {}
                        override fun onServiceResolved(resolved: NsdServiceInfo) {
                            @Suppress("DEPRECATION")
                            if (resolved.host in localAddresses()) found(resolved.port)
                        }
                    })
                }
            }
        }
        nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
        return listener
    }

    /** This phone's ports for [type]: the first one found plus any others within 1.5 s (newest last). */
    private fun findPorts(context: Context, type: String, timeoutMs: Long): List<Int> {
        val ports = LinkedBlockingQueue<Int>()
        val listener = discover(context, type) { ports.offer(it) }
        try {
            val first = ports.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: return emptyList()
            Thread.sleep(1500)
            return (listOf(first) + ports.toList()).distinct().reversed()
        } finally {
            runCatching { context.getSystemService(NsdManager::class.java).stopServiceDiscovery(listener) }
        }
    }

    // ------------------------------------------------------------ notification

    private fun postNotification(context: Context, text: String, askForCode: Boolean, ongoing: Boolean) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Call audio helper setup",
            NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(context, 0, MainActivity.openIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle("Call audio helper")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
        if (askForCode) {
            // RemoteInput needs a mutable PendingIntent; the intent is explicit.
            val reply = PendingIntent.getBroadcast(context, 0,
                Intent(context, PairingCodeReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            builder.addAction(Notification.Action.Builder(Icon.createWithResource(context,
                android.R.drawable.ic_menu_edit), "Enter pairing code", reply)
                .addRemoteInput(RemoteInput.Builder(CODE_KEY).setLabel("Six-digit code").build())
                .build())
        }
        manager.notify(NOTIFICATION_ID, builder.build())
    }

    /** Receives the pairing code typed into the setup notification. */
    class PairingCodeReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val code = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(CODE_KEY)?.toString() ?: return
            onPairingCode(context, code)
        }
    }
}
