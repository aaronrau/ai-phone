package ai.local.receptionist.device

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.net.Uri
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.app.Notification
import ai.local.receptionist.MainActivity

/** Read-only access to the phone's own contacts and calendar, plus owner notifications. */
object DeviceData {
    fun lookupContact(context: Context, number: String): String? {
        if (number.isBlank()) return null
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        return runCatching {
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null)?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
        }.getOrNull()
    }

    fun contacts(context: Context): List<Map<String, String>> {
        val result = ArrayList<Map<String, String>>()
        runCatching {
            context.contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER),
                null, null, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC")?.use { cursor ->
                while (cursor.moveToNext()) {
                    result.add(mapOf("name" to (cursor.getString(0) ?: ""), "number" to (cursor.getString(1) ?: "")))
                }
            }
        }
        return result
    }

    /** Calendar instances overlapping [start, end); titles are included for the owner's agent only. */
    fun calendarEvents(context: Context, start: Long, end: Long): List<Map<String, Any?>> {
        val result = ArrayList<Map<String, Any?>>()
        runCatching {
            CalendarContract.Instances.query(context.contentResolver,
                arrayOf(CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
                    CalendarContract.Instances.TITLE, CalendarContract.Instances.ALL_DAY,
                    CalendarContract.Instances.AVAILABILITY, CalendarContract.Instances.VISIBLE),
                start, end)?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (cursor.getInt(5) == 0) continue
                    result.add(mapOf("start" to cursor.getLong(0), "end" to cursor.getLong(1),
                        "title" to (cursor.getString(2) ?: ""), "allDay" to (cursor.getInt(3) == 1),
                        "busy" to (cursor.getInt(4) != CalendarContract.Instances.AVAILABILITY_FREE)))
                }
            }
        }
        return result.sortedBy { it["start"] as Long }
    }

    /** Assistant updates (messages taken, call outcomes) arrive silently; urgent ones alert. */
    fun notifyOwner(context: Context, title: String, body: String, urgent: Boolean = false) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = if (urgent) "messages" else "assistant_updates"
        manager.createNotificationChannel(if (urgent)
            NotificationChannel("messages", "Urgent messages", NotificationManager.IMPORTANCE_HIGH)
        else NotificationChannel("assistant_updates", "Assistant updates", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(context, 2, MainActivity.openIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, channel)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify((System.currentTimeMillis() % 100000).toInt() + 3000, notification)
    }
}
