package ai.local.receptionist

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import ai.local.receptionist.telephony.CallNotifications

/**
 * Keeps the Flutter receptionist runtime (and resident models) alive while the
 * UI is closed. During an answered call it adds microphone/phone-call types.
 */
class ReceptionistService : Service() {
    companion object {
        private const val ACTION_CALL = "call_mode"
        private const val ACTION_IDLE = "idle_mode"
        private const val ACTION_SHOW_CALL = "show_call"
        private const val EXTRA_NOTIFICATION = "notification"
        private const val NOTIFICATION_ID = 1001

        fun start(context: Context) = send(context, null)
        fun enterCallMode(context: Context) = send(context, ACTION_CALL)
        fun leaveCallMode(context: Context) = send(context, ACTION_IDLE)

        /**
         * Posts a call notification as this service's foreground notification,
         * which lets a call-style notification appear without a full-screen
         * intent (the app stays closed while the phone is in use).
         */
        fun showCall(context: Context, notification: Notification) {
            val intent = Intent(context, ReceptionistService::class.java).setAction(ACTION_SHOW_CALL)
                .putExtra(EXTRA_NOTIFICATION, notification)
            try { context.startForegroundService(intent) }
            catch (failure: Exception) {
                Log.w("ReceptionistService", "call notification via service refused: ${failure.javaClass.simpleName}")
                runCatching { context.getSystemService(NotificationManager::class.java).notify(CallNotifications.ID, notification) }
            }
        }

        private fun send(context: Context, action: String?) {
            val intent = Intent(context, ReceptionistService::class.java).setAction(action)
            try { context.startForegroundService(intent) }
            catch (failure: Exception) { Log.w("ReceptionistService", "start refused: ${failure.javaClass.simpleName}") }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    /** The owner's call notification while a call is up; other starts keep it in front. */
    private var callNotification: Notification? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        EngineHolder.ensure(this)
        if (intent?.action == ACTION_SHOW_CALL) {
            val call = intent.getParcelableExtra(EXTRA_NOTIFICATION, Notification::class.java)
            callNotification = call
            if (call != null) {
                try {
                    startForeground(CallNotifications.ID, call,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
                } catch (failure: Exception) {
                    Log.w("ReceptionistService", "call notification refused: ${failure.message}")
                    runCatching { getSystemService(NotificationManager::class.java).notify(CallNotifications.ID, call) }
                }
            }
            return START_STICKY
        }
        if (intent?.action == ACTION_IDLE) callNotification = null
        val held = callNotification
        if (held != null && intent?.action != ACTION_CALL) {
            // A plain start while the owner's call rings or runs: keep the call notification.
            runCatching {
                startForeground(CallNotifications.ID, held,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
            }
            return START_STICKY
        }
        val callMode = intent?.action == ACTION_CALL
        val baseType = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        val callTypes = baseType or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
        val notification = buildNotification(if (callMode) "Answering a call" else "Ready for calls and texts")
        try {
            startForeground(NOTIFICATION_ID, notification, if (callMode) callTypes else baseType)
        } catch (failure: Exception) {
            Log.w("ReceptionistService", "call-mode foreground refused: ${failure.message}")
            runCatching { startForeground(NOTIFICATION_ID, notification, baseType) }
        }
        // Back to the status notification: drop any call notification this service held.
        if (intent?.action == ACTION_IDLE) getSystemService(NotificationManager::class.java).cancel(CallNotifications.ID)
        if (callMode) acquireWakeLock() else releaseWakeLock()
        // Boot, app update or a plain start: make sure the call-audio helper runs from this APK.
        if (!callMode) ai.local.receptionist.adb.HelperLauncher.ensureRunning(this)
        KeepAliveJob.schedule(this)
        EngineHolder.bridge.emit(mapOf("type" to "service", "callMode" to callMode))
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    /** Some phones stop the service when the app is swiped away; come back. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val restart = android.app.PendingIntent.getForegroundService(this, 7,
            Intent(this, ReceptionistService::class.java),
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
        getSystemService(android.app.AlarmManager::class.java)
            .set(android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP, android.os.SystemClock.elapsedRealtime() + 2000, restart)
        super.onTaskRemoved(rootIntent)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "receptionist:call")
            .apply { acquire(30 * 60 * 1000L) }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun buildNotification(text: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("service", "AI Phone status",
            NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, MainActivity.openIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, "service")
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle("AI Phone")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }
}
