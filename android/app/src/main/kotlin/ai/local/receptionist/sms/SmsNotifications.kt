package ai.local.receptionist.sms

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import ai.local.receptionist.MainActivity

/** Notifications for incoming texts; tapping one opens the conversation. */
object SmsNotifications {
    private const val CHANNEL = "texts"

    fun show(context: Context, threadId: Long, title: String, body: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Texts", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(context, (threadId % 100000).toInt() + 5000,
            MainActivity.threadIntent(context, threadId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.sym_action_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(tag(threadId), 1, notification)
    }

    fun clear(context: Context, threadId: Long) {
        context.getSystemService(NotificationManager::class.java).cancel(tag(threadId), 1)
    }

    private fun tag(threadId: Long) = "thread-$threadId"
}
