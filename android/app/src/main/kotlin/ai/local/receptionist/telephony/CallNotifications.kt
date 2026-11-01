package ai.local.receptionist.telephony

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.telecom.Call
import ai.local.receptionist.MainActivity
import ai.local.receptionist.ReceptionistService
import ai.local.receptionist.device.DeviceData

/** Call notifications: the owner's calls, and calls the assistant is handling. */
object CallNotifications {
    private const val CHANNEL = "calls"
    private const val AI_CHANNEL = "assistant_calls"
    private const val TRANSFER_CHANNEL = "transfers"
    const val ID = 2001

    /** Title and text of each assistant call's notification, by call id. */
    private val aiNotes = java.util.concurrent.ConcurrentHashMap<String, Pair<String, String>>()

    /** Call whose warm-transfer alert is showing; kept until the app replaces it. */
    @Volatile private var transferFor: String? = null

    /** Updates an assistant call's notification text (shown when no owner call needs the slot). */
    fun setAi(context: Context, callId: String, title: String, text: String) {
        aiNotes[callId] = title to text
        if (transferFor == callId) transferFor = null
        refresh(context)
    }

    /**
     * There is one call notification; with several calls it shows the one that
     * needs the owner most: a ringing call (Answer / Decline, also as call
     * waiting), then the owner's active, dialing and held calls, then a call the
     * assistant is handling.
     */
    fun refresh(context: Context) {
        val live = CallRegistry.all().filterValues { it.details?.state != Call.STATE_DISCONNECTED }
        aiNotes.keys.retainAll(live.keys)
        if (live.isEmpty()) { transferFor = null; cancel(context); return }
        fun rank(call: Call) = when (call.details?.state) {
            Call.STATE_RINGING -> 0
            Call.STATE_ACTIVE -> 1
            Call.STATE_HOLDING -> 3
            else -> 2
        }
        val owner = live.entries.filter { !CallRegistry.isAi(it.key, it.value) }.minByOrNull { rank(it.value) }
        if (owner != null) { show(context, owner.key, owner.value); return }
        if (transferFor != null && live.containsKey(transferFor)) return
        val (id, call) = live.entries.first()
        val (title, text) = aiNotes[id] ?: ("AI assistant is answering" to CallRegistry.number(call).ifBlank { "Unknown caller" })
        showAi(context, id, title, text)
    }

    /**
     * The owner's own calls, as a notification instead of a full-screen app:
     * ringing calls get Answer / Decline (full screen only on the lock screen,
     * as Android does for every phone app); calls in progress get a timer,
     * Speaker and Hang up. Tapping opens the in-app call screen.
     */
    fun show(context: Context, callId: String, call: Call) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Calls", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(context, 1, MainActivity.callIntent(context, callId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val state = call.details?.state ?: Call.STATE_NEW
        val number = CallRegistry.number(call)
        val name = DeviceData.lookupContact(context, number) ?: number.ifBlank { "Unknown caller" }
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setOnlyAlertOnce(state != Call.STATE_RINGING)
            .setContentIntent(open)
        if (state == Call.STATE_RINGING) {
            val person = Person.Builder().setName(name).setImportant(true).build()
            builder.setStyle(Notification.CallStyle.forIncomingCall(person,
                    action(context, CallActionReceiver.DECLINE, callId, 21),
                    action(context, CallActionReceiver.ANSWER, callId, 22)))
            // Full screen only when the phone is locked or asleep; in use, the call
            // stays a notification (some phones launch a full-screen intent anyway).
            if (lockedOrAsleep(context)) builder.setFullScreenIntent(open, true)
        } else {
            val connected = call.details?.connectTimeMillis ?: 0L
            val active = state == Call.STATE_ACTIVE && connected > 0
            builder.setContentTitle(name)
                .setContentText(when (state) {
                    Call.STATE_HOLDING -> "On hold"
                    Call.STATE_ACTIVE -> "On call"
                    else -> "Calling…"
                })
                .setWhen(if (active) connected else System.currentTimeMillis())
                .setUsesChronometer(active)
                .setShowWhen(active)
                .addAction(if (state == Call.STATE_HOLDING)
                    Notification.Action.Builder(null, "Resume", action(context, CallActionReceiver.RESUME, callId, 25)).build()
                else Notification.Action.Builder(null,
                    if (CallRegistry.isSpeaker()) "Speaker off" else "Speaker",
                    action(context, CallActionReceiver.SPEAKER, callId, 23)).build())
                .addAction(Notification.Action.Builder(null, "Hang up",
                    action(context, CallActionReceiver.HANG_UP, callId, 24)).build())
        }
        ReceptionistService.showCall(context, builder.build())
    }

    private fun lockedOrAsleep(context: Context): Boolean =
        context.getSystemService(KeyguardManager::class.java).isKeyguardLocked ||
            !context.getSystemService(PowerManager::class.java).isInteractive

    private fun action(context: Context, name: String, callId: String, code: Int): PendingIntent =
        PendingIntent.getBroadcast(context, code,
            Intent(context, CallActionReceiver::class.java).setAction(name).putExtra("callId", callId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /**
     * Warm transfer: a known contact is on an assistant call and wants the
     * owner. Alerts and opens the app full screen with Pick up / Not now.
     */
    fun showTransfer(context: Context, callId: String, title: String, text: String) {
        transferFor = callId
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(TRANSFER_CHANNEL, "Calls for you to pick up", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(context, 3, MainActivity.callIntent(context, callId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, TRANSFER_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle(title)
            .setContentText(text.ifBlank { "Wants to talk to you" })
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
            // Pick up opens the app directly (Android blocks activity starts from
            // notification-action receivers).
            .addAction(Notification.Action.Builder(null, "Pick up", PendingIntent.getActivity(context, 31,
                MainActivity.pickUpIntent(context, callId),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)).build())
            .addAction(Notification.Action.Builder(null, "Not now",
                action(context, CallActionReceiver.NOT_NOW, callId, 32)).build())
            .build()
        // Through the service, which re-posts its held call notification on later starts.
        ReceptionistService.showCall(context, notification)
    }

    /** Quiet ongoing notification for a call the AI is handling (no pop-up). */
    fun showAi(context: Context, callId: String, title: String, text: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(AI_CHANNEL, "Calls answered by the assistant", NotificationManager.IMPORTANCE_LOW))
        fun action(name: String, code: Int) = PendingIntent.getBroadcast(context, code,
            Intent(context, CallActionReceiver::class.java).setAction(name).putExtra("callId", callId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(context, 1, MainActivity.callIntent(context, callId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, AI_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle(title)
            .setContentText(text)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Take over", action(CallActionReceiver.TAKE_OVER, 11)).build())
            .addAction(Notification.Action.Builder(null, "Hang up", action(CallActionReceiver.HANG_UP, 12)).build())
            .build()
        // Through the service, which re-posts its held call notification on later starts.
        ReceptionistService.showCall(context, notification)
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(ID)
        // If the service holds the call notification, release it too.
        if (CallRegistry.all().isEmpty()) ReceptionistService.leaveCallMode(context)
    }
}
