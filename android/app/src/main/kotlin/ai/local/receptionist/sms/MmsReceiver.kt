package ai.local.receptionist.sms

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import ai.local.receptionist.EngineHolder
import ai.local.receptionist.ReceptionistService

/**
 * Picture and group messages. The push only says a message is waiting; the
 * phone's MMS service downloads it into a file, which is parsed and saved to
 * the system store, then handed to Dart like a text.
 */
class MmsReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "MmsReceiver"
        const val ACTION_DOWNLOADED = "ai.local.receptionist.MMS_DOWNLOADED"
        private const val EXTRA_FILE = "file"
        private const val EXTRA_LOCATION = "location"
        private const val EXTRA_TRANSACTION = "transaction"
        private val recent = ArrayDeque<String>()
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Telephony.Sms.Intents.WAP_PUSH_DELIVER_ACTION -> onPush(context, intent)
            ACTION_DOWNLOADED -> onDownloaded(context, intent)
        }
    }

    private fun onPush(context: Context, intent: Intent) {
        val pdu = MmsPdu.parse(intent.getByteArrayExtra("data") ?: return) ?: return
        if (pdu.messageType != MmsPdu.NOTIFICATION_IND || pdu.contentLocation.isEmpty()) return
        synchronized(recent) {
            if (pdu.transactionId in recent) return // the network repeated the notification
            recent.addLast(pdu.transactionId); if (recent.size > 20) recent.removeFirst()
        }
        val name = "dl-${System.currentTimeMillis()}.pdu"
        val done = Intent(context, MmsReceiver::class.java).setAction(ACTION_DOWNLOADED)
            .putExtra(EXTRA_FILE, name).putExtra(EXTRA_LOCATION, pdu.contentLocation)
            .putExtra(EXTRA_TRANSACTION, pdu.transactionId)
        val pending = PendingIntent.getBroadcast(context, name.hashCode(), done,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
        val subscription = intent.getIntExtra("subscription", SmsManager.getDefaultSmsSubscriptionId())
        Log.i(TAG, "downloading picture message size=${pdu.messageSize}")
        runCatching {
            SmsManager.getSmsManagerForSubscriptionId(subscription).downloadMultimediaMessage(
                context, pdu.contentLocation, MmsFileProvider.uri(name), null, pending)
        }.onFailure { Log.e(TAG, "download request failed", it) }
    }

    private fun onDownloaded(context: Context, intent: Intent) {
        val name = intent.getStringExtra(EXTRA_FILE) ?: return
        val file = MmsFileProvider.file(context, name)
        if (resultCode != Activity.RESULT_OK || !file.exists()) {
            Log.w(TAG, "download failed result=$resultCode")
            file.delete()
            return
        }
        val pending = goAsync()
        Thread {
            try {
                val pdu = MmsPdu.parse(file.readBytes())
                file.delete()
                if (pdu == null || pdu.messageType != MmsPdu.RETRIEVE_CONF) {
                    Log.w(TAG, "could not read downloaded message")
                    return@Thread
                }
                val threadId = persist(context, pdu)
                acknowledge(context, intent.getStringExtra(EXTRA_TRANSACTION) ?: pdu.transactionId)
                val text = pdu.parts.filter { it.contentType == "text/plain" }.joinToString(" ") { it.text() }.trim()
                val pictures = pdu.parts.count { it.contentType.startsWith("image/") }
                val body = listOf(text, if (pictures > 0) "(${if (pictures == 1) "picture" else "$pictures pictures"})" else "")
                    .filter { it.isNotEmpty() }.joinToString(" ")
                ReceptionistService.start(context)
                EngineHolder.ensure(context)
                EngineHolder.bridge.emit(mapOf("type" to "sms", "number" to pdu.from, "body" to body,
                    "time" to pdu.dateSeconds * 1000, "threadId" to threadId, "stored" to true, "mms" to true,
                    "group" to (pdu.to.size > 1)))
            } catch (failure: Throwable) {
                Log.e(TAG, "saving picture message failed", failure)
            } finally {
                pending.finish()
            }
        }.start()
    }

    /** Saves a retrieved message (with its parts) to the system MMS store. */
    private fun persist(context: Context, pdu: MmsPdu): Long {
        val resolver = context.contentResolver
        val recipients = (listOf(pdu.from) + pdu.to).filter { it.isNotBlank() }.toSet()
        val threadId = runCatching { Telephony.Threads.getOrCreateThreadId(context, recipients) }.getOrDefault(-1L)
        val values = ContentValues().apply {
            put(Telephony.Mms.THREAD_ID, threadId)
            put(Telephony.Mms.DATE, System.currentTimeMillis() / 1000)
            put(Telephony.Mms.DATE_SENT, pdu.dateSeconds)
            put(Telephony.Mms.MESSAGE_BOX, Telephony.Mms.MESSAGE_BOX_INBOX)
            put(Telephony.Mms.READ, 0)
            put(Telephony.Mms.SEEN, 0)
            put(Telephony.Mms.MESSAGE_TYPE, MmsPdu.RETRIEVE_CONF)
            put(Telephony.Mms.MMS_VERSION, 0x12)
            put(Telephony.Mms.CONTENT_TYPE, "application/vnd.wap.multipart.related")
            if (pdu.subject.isNotEmpty()) put(Telephony.Mms.SUBJECT, pdu.subject)
            if (pdu.messageId.isNotEmpty()) put(Telephony.Mms.MESSAGE_ID, pdu.messageId)
            if (pdu.transactionId.isNotEmpty()) put(Telephony.Mms.TRANSACTION_ID, pdu.transactionId)
        }
        val message = resolver.insert(Telephony.Mms.Inbox.CONTENT_URI, values) ?: return threadId
        val id = message.lastPathSegment ?: return threadId
        fun address(value: String, type: Int) = resolver.insert(Uri.parse("content://mms/$id/addr"), ContentValues().apply {
            put(Telephony.Mms.Addr.ADDRESS, value); put(Telephony.Mms.Addr.TYPE, type); put(Telephony.Mms.Addr.CHARSET, 106)
        })
        if (pdu.from.isNotBlank()) address(pdu.from, 137)
        for (to in pdu.to) address(to, 151)
        for ((index, part) in pdu.parts.withIndex()) {
            val row = ContentValues().apply {
                put(Telephony.Mms.Part.MSG_ID, id.toLong())
                put(Telephony.Mms.Part.SEQ, index)
                put(Telephony.Mms.Part.CONTENT_TYPE, part.contentType)
                put(Telephony.Mms.Part.CONTENT_LOCATION, part.name.ifEmpty { "part$index" })
                if (part.contentType.startsWith("text/")) {
                    put(Telephony.Mms.Part.CHARSET, 106)
                    put(Telephony.Mms.Part.TEXT, part.text())
                }
            }
            val partUri = resolver.insert(Uri.parse("content://mms/$id/part"), row) ?: continue
            if (!part.contentType.startsWith("text/")) {
                runCatching { resolver.openOutputStream(partUri)?.use { it.write(part.data) } }
            }
        }
        return threadId
    }

    /** Tells the MMS center the message arrived so it is not offered again. */
    private fun acknowledge(context: Context, transactionId: String) {
        if (transactionId.isEmpty()) return
        runCatching {
            val name = "ack-${System.currentTimeMillis()}.pdu"
            MmsFileProvider.file(context, name).writeBytes(notifyResponse(transactionId))
            context.getSystemService(SmsManager::class.java)
                .sendMultimediaMessage(context, MmsFileProvider.uri(name), null, null, null)
        }.onFailure { Log.w(TAG, "acknowledgement failed", it) }
    }
}
