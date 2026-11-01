package ai.local.receptionist.sms

import android.app.PendingIntent
import android.app.role.RoleManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log

/**
 * The system SMS/MMS store, as the default messaging app sees it. Once this app
 * holds the SMS role the platform no longer saves incoming or sent texts, so
 * every message is written here, and conversations are read back from here.
 */
object SmsStore {
    private const val TAG = "SmsStore"
    private val CONVERSATIONS: Uri = Uri.parse("content://mms-sms/conversations?simple=true")
    private val CANONICAL: Uri = Uri.parse("content://mms-sms/canonical-addresses")

    /** Holding the SMS role. (getDefaultSmsPackage can lag behind the role on some phones.) */
    fun isDefault(context: Context): Boolean =
        context.getSystemService(RoleManager::class.java)?.isRoleHeld(RoleManager.ROLE_SMS) == true ||
            Telephony.Sms.getDefaultSmsPackage(context) == context.packageName

    /** Saves an incoming text; returns its thread ID (or -1 when not saved). */
    fun saveIncoming(context: Context, address: String, body: String, sentAt: Long, subscriptionId: Int): Long {
        if (!isDefault(context)) return threadFor(context, address)
        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, System.currentTimeMillis())
            put(Telephony.Sms.DATE_SENT, sentAt)
            put(Telephony.Sms.READ, 0)
            put(Telephony.Sms.SEEN, 0)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX)
            if (subscriptionId >= 0) put(Telephony.Sms.SUBSCRIPTION_ID, subscriptionId)
        }
        val uri = runCatching { context.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, values) }
            .onFailure { Log.e(TAG, "saving incoming text failed", it) }.getOrNull()
        Log.i(TAG, "incoming saved=${uri != null}")
        return uri?.let { threadOf(context, it) } ?: threadFor(context, address)
    }

    /** Sends a text and, as the default app, records it in the Sent folder. */
    fun send(context: Context, number: String, text: String): Long {
        val manager = context.getSystemService(SmsManager::class.java)
        val parts = manager.divideMessage(text)
        var uri: Uri? = null
        if (isDefault(context)) {
            val values = ContentValues().apply {
                put(Telephony.Sms.ADDRESS, number)
                put(Telephony.Sms.BODY, text)
                put(Telephony.Sms.DATE, System.currentTimeMillis())
                put(Telephony.Sms.READ, 1)
                put(Telephony.Sms.SEEN, 1)
                put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_OUTBOX)
            }
            uri = runCatching { context.contentResolver.insert(Telephony.Sms.Sent.CONTENT_URI, values) }
                .onFailure { Log.e(TAG, "saving sent text failed", it) }.getOrNull()
        }
        val sent = ArrayList<PendingIntent>()
        for (i in parts.indices) {
            val intent = Intent(context, SmsSentReceiver::class.java).setData(uri)
                .putExtra(SmsSentReceiver.EXTRA_LAST, i == parts.size - 1)
            sent += PendingIntent.getBroadcast(context, (System.nanoTime() % Int.MAX_VALUE).toInt() + i, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        if (parts.size <= 1) manager.sendTextMessage(number, null, text, sent.firstOrNull(), null)
        else manager.sendMultipartTextMessage(number, null, parts, sent, null)
        Log.i(TAG, "send parts=${parts.size} default=${uri != null || isDefault(context)} saved=${uri != null}")
        return uri?.let { threadOf(context, it) } ?: threadFor(context, number)
    }

    fun markSent(context: Context, uri: Uri, ok: Boolean) {
        val values = ContentValues().apply {
            put(Telephony.Sms.TYPE, if (ok) Telephony.Sms.MESSAGE_TYPE_SENT else Telephony.Sms.MESSAGE_TYPE_FAILED)
        }
        runCatching { context.contentResolver.update(uri, values, null, null) }
    }

    fun threadFor(context: Context, address: String): Long =
        runCatching { Telephony.Threads.getOrCreateThreadId(context, address) }.getOrDefault(-1L)

    private fun threadOf(context: Context, uri: Uri): Long? =
        context.contentResolver.query(uri, arrayOf(Telephony.Sms.THREAD_ID), null, null, null)?.use {
            if (it.moveToFirst()) it.getLong(0) else null
        }

    /** Conversations, newest first: threadId, addresses, snippet, date, unread, count. */
    fun threads(context: Context, limit: Int): List<Map<String, Any?>> {
        val addresses = HashMap<Long, String>()
        context.contentResolver.query(CANONICAL, arrayOf("_id", "address"), null, null, null)?.use {
            while (it.moveToNext()) addresses[it.getLong(0)] = it.getString(1) ?: ""
        }
        val result = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(CONVERSATIONS,
            arrayOf("_id", "date", "message_count", "recipient_ids", "snippet", "read"),
            null, null, "date DESC")?.use {
            while (it.moveToNext() && result.size < limit) {
                if (it.getInt(2) == 0) continue
                val ids = (it.getString(3) ?: "").split(' ').mapNotNull { id -> id.toLongOrNull() }
                result += mapOf(
                    "threadId" to it.getLong(0),
                    "date" to it.getLong(1),
                    "count" to it.getInt(2),
                    "addresses" to ids.mapNotNull { id -> addresses[id] },
                    "snippet" to (it.getString(4) ?: ""),
                    "unread" to (it.getInt(5) == 0),
                )
            }
        }
        return result
    }

    /** Messages in a thread, oldest first: SMS plus MMS text and picture parts. */
    fun messages(context: Context, threadId: Long, limit: Int): List<Map<String, Any?>> {
        val result = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
            "${Telephony.Sms.THREAD_ID} = ?", arrayOf(threadId.toString()), "${Telephony.Sms.DATE} DESC")?.use {
            while (it.moveToNext() && result.size < limit) {
                val type = it.getInt(4)
                result += mapOf(
                    "id" to "sms-${it.getLong(0)}",
                    "address" to (it.getString(1) ?: ""),
                    "body" to (it.getString(2) ?: ""),
                    "date" to it.getLong(3),
                    "outgoing" to (type != Telephony.Sms.MESSAGE_TYPE_INBOX),
                    "failed" to (type == Telephony.Sms.MESSAGE_TYPE_FAILED),
                    "pending" to (type == Telephony.Sms.MESSAGE_TYPE_OUTBOX || type == Telephony.Sms.MESSAGE_TYPE_QUEUED),
                    "images" to emptyList<Long>(),
                )
            }
        }
        context.contentResolver.query(Telephony.Mms.CONTENT_URI,
            arrayOf(Telephony.Mms._ID, Telephony.Mms.DATE, Telephony.Mms.MESSAGE_BOX),
            "${Telephony.Mms.THREAD_ID} = ?", arrayOf(threadId.toString()), "${Telephony.Mms.DATE} DESC")?.use {
            var count = 0
            while (it.moveToNext() && count++ < limit) {
                val id = it.getLong(0)
                val outgoing = it.getInt(2) != Telephony.Mms.MESSAGE_BOX_INBOX
                val (text, images) = mmsParts(context, id)
                result += mapOf(
                    "id" to "mms-$id",
                    "address" to (if (outgoing) "" else mmsSender(context, id)),
                    "body" to text,
                    "date" to it.getLong(1) * 1000,
                    "outgoing" to outgoing,
                    "failed" to false,
                    "pending" to false,
                    "images" to images,
                )
            }
        }
        return result.sortedBy { it["date"] as Long }.takeLast(limit)
    }

    private fun mmsParts(context: Context, id: Long): Pair<String, List<Long>> {
        val text = StringBuilder()
        val images = ArrayList<Long>()
        context.contentResolver.query(Uri.parse("content://mms/part"), arrayOf("_id", "ct", "text"),
            "mid = ?", arrayOf(id.toString()), null)?.use {
            while (it.moveToNext()) {
                val type = it.getString(1) ?: ""
                when {
                    type == "text/plain" -> text.append(it.getString(2) ?: "")
                    type.startsWith("image/") -> images += it.getLong(0)
                }
            }
        }
        return text.toString() to images
    }

    private fun mmsSender(context: Context, id: Long): String =
        context.contentResolver.query(Uri.parse("content://mms/$id/addr"), arrayOf("address"),
            "type = 137", null, null)?.use { if (it.moveToFirst()) it.getString(0) ?: "" else "" } ?: ""

    fun partBytes(context: Context, partId: Long): ByteArray? = runCatching {
        context.contentResolver.openInputStream(Uri.parse("content://mms/part/$partId"))?.use { it.readBytes() }
    }.getOrNull()

    fun markRead(context: Context, threadId: Long) {
        val values = ContentValues().apply { put("read", 1); put("seen", 1) }
        runCatching {
            context.contentResolver.update(Telephony.Sms.CONTENT_URI, values, "thread_id = ? AND read = 0",
                arrayOf(threadId.toString()))
            context.contentResolver.update(Telephony.Mms.CONTENT_URI, values, "thread_id = ? AND read = 0",
                arrayOf(threadId.toString()))
        }
    }

    fun deleteThread(context: Context, threadId: Long): Int = runCatching {
        context.contentResolver.delete(Uri.parse("content://mms-sms/conversations/$threadId"), null, null)
    }.getOrDefault(0)
}
