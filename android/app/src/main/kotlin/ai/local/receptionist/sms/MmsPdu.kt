package ai.local.receptionist.sms

import java.io.ByteArrayOutputStream
import java.nio.charset.Charset

/**
 * Minimal reader for MMS PDUs (OMA MMS encapsulation over WSP): the
 * notification that a message is waiting, and the retrieved message with its
 * sender, recipients, date, subject and parts. Unknown headers are skipped
 * with the generic WSP value rules.
 */
class MmsPdu private constructor(
    val messageType: Int,
    val transactionId: String,
    val messageId: String,
    val from: String,
    val to: List<String>,
    val subject: String,
    val dateSeconds: Long,
    val contentLocation: String,
    val messageSize: Long,
    val parts: List<Part>,
) {
    class Part(val contentType: String, val name: String, val charset: Int, val data: ByteArray) {
        fun text(): String = String(data, charsetFor(charset))
    }

    companion object {
        const val NOTIFICATION_IND = 0x82
        const val RETRIEVE_CONF = 0x84

        private const val BCC = 0x01; private const val CC = 0x02; private const val CONTENT_LOCATION = 0x03
        private const val CONTENT_TYPE = 0x04; private const val DATE = 0x05; private const val FROM = 0x09
        private const val MESSAGE_ID = 0x0B; private const val MESSAGE_TYPE = 0x0C; private const val MESSAGE_SIZE = 0x0E
        private const val SUBJECT = 0x16; private const val TO = 0x17; private const val TRANSACTION_ID = 0x18

        /** WSP well-known content types used by MMS (WAP-230 table 40). */
        private val MEDIA = mapOf(
            0x00 to "*/*", 0x01 to "text/*", 0x02 to "text/html", 0x03 to "text/plain", 0x06 to "text/x-vCalendar",
            0x07 to "text/x-vCard", 0x1C to "image/*", 0x1D to "image/gif", 0x1E to "image/jpeg", 0x1F to "image/tiff",
            0x20 to "image/png", 0x21 to "image/vnd.wap.wbmp", 0x22 to "application/vnd.wap.multipart.*",
            0x23 to "application/vnd.wap.multipart.mixed", 0x33 to "application/vnd.wap.multipart.related",
            0x34 to "application/vnd.wap.multipart.alternative",
        )

        fun charsetFor(mib: Int): Charset = runCatching {
            when (mib) {
                3 -> Charsets.US_ASCII; 4 -> Charsets.ISO_8859_1; 1000 -> Charsets.UTF_16
                1015 -> Charsets.UTF_16; else -> Charsets.UTF_8
            }
        }.getOrDefault(Charsets.UTF_8)

        fun parse(bytes: ByteArray): MmsPdu? = runCatching { Reader(bytes).pdu() }.getOrNull()
    }

    private class Reader(val b: ByteArray) {
        var i = 0
        fun u(): Int = b[i++].toInt() and 0xFF
        fun peek(): Int = b[i].toInt() and 0xFF

        fun uintvar(): Long {
            var value = 0L
            while (true) {
                val v = u()
                value = (value shl 7) or (v and 0x7F).toLong()
                if (v and 0x80 == 0) return value
            }
        }

        /** Value-length: a short length (0-30) or 31 followed by a uintvar. */
        fun valueLength(): Int {
            val first = u()
            return if (first < 31) first else uintvar().toInt()
        }

        fun text(): String {
            if (peek() == 127) i++ // quote
            val start = i
            while (i < b.size && b[i].toInt() != 0) i++
            val s = String(b, start, i - start, Charsets.UTF_8)
            if (i < b.size) i++
            return s.removePrefix("\"")
        }

        fun longInt(): Long {
            val length = u()
            var value = 0L
            repeat(length) { value = (value shl 8) or u().toLong() }
            return value
        }

        fun integer(): Long = if (peek() >= 0x80) (u() and 0x7F).toLong() else longInt()

        /** Encoded-string-value: text, or length + charset + text. */
        fun encodedString(): String {
            val first = peek()
            if (first in 32..127 || first == 0) return text()
            val length = valueLength()
            val end = i + length
            val charset = integer().toInt()
            val start = i
            var stop = start
            while (stop < end && b[stop].toInt() != 0) stop++
            var from = start
            if (from < stop && (b[from].toInt() and 0xFF) == 127) from++
            val s = String(b, from, stop - from, charsetFor(charset))
            i = end
            return s
        }

        /** Skips any WSP value. */
        fun skipValue() {
            val first = peek()
            when {
                first < 31 -> { u(); i += first }
                first == 31 -> { u(); i += uintvar().toInt() }
                first < 128 -> text()
                else -> u()
            }
        }

        /** Content-type value: returns (media type, charset, name). */
        fun contentType(): Triple<String, Int, String> {
            val first = peek()
            if (first >= 0x80) return Triple(MEDIA[u() and 0x7F] ?: "application/octet-stream", 106, "")
            if (first in 32..127) return Triple(text(), 106, "")
            val length = valueLength()
            val end = i + length
            val media = if (peek() >= 0x80) MEDIA[u() and 0x7F] ?: "application/octet-stream"
                else if (peek() < 31) { skipValue(); "application/octet-stream" } else text()
            var charset = 106
            var name = ""
            while (i < end) {
                val param = peek()
                if (param >= 0x80) {
                    u()
                    when (param and 0x7F) {
                        0x01 -> charset = integer().toInt()          // charset
                        0x05, 0x17 -> name = text()                  // name
                        0x06, 0x18 -> name = text()                  // filename
                        else -> skipValue()
                    }
                } else {
                    val key = text().lowercase()
                    if (key == "charset") charset = if (peek() >= 0x80 || peek() < 31) integer().toInt() else 106.also { text() }
                    else if (key == "name") name = text() else skipValue()
                }
            }
            i = end
            return Triple(media, charset, name)
        }

        fun pdu(): MmsPdu {
            var type = 0; var transaction = ""; var messageId = ""; var from = ""; var subject = ""
            var date = 0L; var location = ""; var size = 0L
            val to = ArrayList<String>()
            var parts: List<Part> = emptyList()
            while (i < b.size) {
                val field = u()
                if (field < 0x80) { i--; text(); text(); continue } // application header: name, value
                when (field and 0x7F) {
                    MESSAGE_TYPE -> type = u()
                    TRANSACTION_ID -> transaction = text()
                    MESSAGE_ID -> messageId = text()
                    CONTENT_LOCATION -> location = text()
                    SUBJECT -> subject = encodedString()
                    DATE -> date = longInt()
                    MESSAGE_SIZE -> size = longInt()
                    TO, CC -> to += encodedString().substringBefore("/TYPE=")
                    BCC -> encodedString()
                    FROM -> {
                        val length = valueLength()
                        val end = i + length
                        if (u() == 0x80) from = encodedString().substringBefore("/TYPE=")
                        i = end
                    }
                    CONTENT_TYPE -> {
                        contentType()
                        parts = multipart()
                        break
                    }
                    else -> skipValue()
                }
            }
            return MmsPdu(type, transaction, messageId, from, to, subject, date, location, size, parts)
        }

        fun multipart(): List<Part> {
            if (i >= b.size) return emptyList()
            val count = uintvar().toInt()
            val parts = ArrayList<Part>()
            repeat(count) {
                val headersLength = uintvar().toInt()
                val dataLength = uintvar().toInt()
                val headersEnd = i + headersLength
                val (type, charset, typeName) = contentType()
                var name = typeName
                while (i < headersEnd) {
                    val header = u()
                    if (header >= 0x80) {
                        when (header and 0x7F) {
                            0x0E, 0x40 -> name = name.ifEmpty { text().trim('<', '>') } // content-location / id
                            else -> skipValue()
                        }
                    } else { i--; text(); text() }
                }
                i = headersEnd
                val data = b.copyOfRange(i, i + dataLength)
                i += dataLength
                parts += Part(type, name, charset, data)
            }
            return parts
        }
    }
}

/** Builds an M-NotifyResp.ind telling the MMS center the message was retrieved. */
fun notifyResponse(transactionId: String): ByteArray = ByteArrayOutputStream().apply {
    write(0x8C); write(0x83)                       // message type: m-notifyresp-ind
    write(0x98); write(transactionId.toByteArray(Charsets.UTF_8)); write(0)
    write(0x8D); write(0x92)                       // MMS version 1.2
    write(0x95); write(0x81)                       // status: retrieved
}.toByteArray()
