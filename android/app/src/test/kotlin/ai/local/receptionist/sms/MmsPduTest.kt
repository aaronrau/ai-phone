package ai.local.receptionist.sms

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/** PDUs built by hand from the OMA MMS encapsulation (WAP-209) byte layout. */
class MmsPduTest {
    private fun bytes(build: ByteArrayOutputStream.() -> Unit) = ByteArrayOutputStream().apply(build).toByteArray()
    private fun ByteArrayOutputStream.text(value: String) { write(value.toByteArray()); write(0) }
    private fun ByteArrayOutputStream.uintvar(value: Int) {
        if (value >= 0x80) write(0x80 or (value shr 7))
        write(value and 0x7F)
    }

    @Test fun readsNotification() {
        val pdu = MmsPdu.parse(bytes {
            write(0x8C); write(0x82)                               // m-notification-ind
            write(0x98); text("T123")                              // transaction id
            write(0x8D); write(0x92)                               // version 1.2
            write(0x89); write(14); write(0x80); text("+15555550100/TYPE=PLMN".take(12)) // from
            write(0x8A); write(0x80)                               // class: personal
            write(0x8E); write(2); write(0x30); write(0x39)        // size 12345
            write(0x88); write(5); write(0x81); write(3); write(0x01); write(0x51); write(0x80) // expiry (relative)
            write(0x83); text("http://mmsc.example.invalid/m/abc") // content location
        })
        assertNotNull(pdu)
        assertEquals(MmsPdu.NOTIFICATION_IND, pdu!!.messageType)
        assertEquals("T123", pdu.transactionId)
        assertEquals("http://mmsc.example.invalid/m/abc", pdu.contentLocation)
        assertEquals(12345L, pdu.messageSize)
    }

    @Test fun readsRetrievedMessageWithTextAndPicture() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 0xFF.toByte(), 0xD9.toByte())
        val textPart = "Hello there".toByteArray()
        val pdu = MmsPdu.parse(bytes {
            write(0x8C); write(0x84)                               // m-retrieve-conf
            write(0x98); text("T9")
            write(0x8B); text("MID-1")                             // message id
            write(0x8D); write(0x92)
            write(0x85); write(4); write(0x65); write(0x53); write(0xF1); write(0x00) // date
            val from = "+15555550100/TYPE=PLMN"
            write(0x89); write(from.length + 2); write(0x80); text(from)
            write(0x97); text("+15555550101/TYPE=PLMN")            // to
            write(0x97); text("+15555550102/TYPE=PLMN")            // to (group)
            write(0x96); write(14); write(0xEA); text("Weekend pics")  // subject, utf-8
            write(0x84); write(0xB3)                               // content type: multipart.related
            uintvar(2)
            // part 1: text/plain; charset=utf-8
            val textHeaders = bytes { write(3); write(0x83); write(0x81); write(0xEA) }
            uintvar(textHeaders.size); uintvar(textPart.size); write(textHeaders); write(textPart)
            // part 2: image/jpeg with a content-location header
            val imageHeaders = bytes { write(0x9E); write(0x8E); text("photo.jpg") }
            uintvar(imageHeaders.size); uintvar(jpeg.size); write(imageHeaders); write(jpeg)
        })
        assertNotNull(pdu)
        pdu!!
        assertEquals(MmsPdu.RETRIEVE_CONF, pdu.messageType)
        assertEquals("+15555550100", pdu.from)
        assertEquals(listOf("+15555550101", "+15555550102"), pdu.to)
        assertEquals("Weekend pics", pdu.subject)
        assertEquals(0x6553F100L, pdu.dateSeconds)
        assertEquals(2, pdu.parts.size)
        assertEquals("text/plain", pdu.parts[0].contentType)
        assertEquals("Hello there", pdu.parts[0].text())
        assertEquals("image/jpeg", pdu.parts[1].contentType)
        assertEquals("photo.jpg", pdu.parts[1].name)
        assertEquals(jpeg.toList(), pdu.parts[1].data.toList())
    }

    @Test fun buildsNotifyResponse() {
        val ack = notifyResponse("T9")
        assertEquals(listOf(0x8C, 0x83, 0x98, 'T'.code, '9'.code, 0, 0x8D, 0x92, 0x95, 0x81), ack.map { it.toInt() and 0xFF })
    }
}
