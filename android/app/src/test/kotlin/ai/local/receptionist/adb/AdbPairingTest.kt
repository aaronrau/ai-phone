package ai.local.receptionist.adb

import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdbPairingTest {
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    private val client = "adb pair client\u0000".toByteArray()
    private val server = "adb pair server\u0000".toByteArray()

    /** The encodings published in BoringSSL's spake25519.c. */
    @Test fun maskPointsMatchBoringSsl() {
        assertEquals("5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e", hex(Spake2.M.encode()))
        assertEquals("10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778", hex(Spake2.N.encode()))
    }

    @Test fun peersWithTheSameCodeAgree() {
        val alice = Spake2(alice = true, myName = client, theirName = server)
        val bob = Spake2(alice = false, myName = server, theirName = client)
        val a = alice.generateMessage("123456".toByteArray())
        val b = bob.generateMessage("123456".toByteArray())
        val key = alice.processMessage(b)
        assertEquals(64, key.size)
        assertArrayEquals(key, bob.processMessage(a))
    }

    @Test fun aWrongCodeGivesDifferentKeys() {
        val alice = Spake2(alice = true, myName = client, theirName = server)
        val bob = Spake2(alice = false, myName = server, theirName = client)
        val a = alice.generateMessage("123456".toByteArray())
        val b = bob.generateMessage("654321".toByteArray())
        assertFalse(alice.processMessage(b).contentEquals(bob.processMessage(a)))
    }

    @Test fun encodeDecodeRoundTrips() {
        val point = Spake2.Point.mul(BigInteger.valueOf(123456789), Spake2.Point.BASE)
        assertArrayEquals(point.encode(), Spake2.Point.decode(point.encode())!!.encode())
    }

    /** adb's mincrypt RSAPublicKey: 64 words, n0inv, modulus, R², exponent, then " name" and a NUL. */
    @Test fun publicKeyUsesAdbFormat() {
        val dir = Files.createTempDirectory("adbkey").toFile()
        try {
            val key = AdbKey.loadOrCreate(dir)
            val text = String(key.adbPublicKey())
            assertTrue(text.endsWith(" receptionist@aiphone\u0000"))
            val raw = Base64.getDecoder().decode(text.substringBefore(' '))
            assertEquals(524, raw.size)
            val words = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(64, words.int)
            val n0inv = words.int.toLong() and 0xffffffffL
            val n = key.publicKey.modulus
            assertEquals(BigInteger.ONE.shiftLeft(32).subtract(BigInteger.ONE),
                n.multiply(BigInteger.valueOf(n0inv)).mod(BigInteger.ONE.shiftLeft(32)))
            assertEquals(n, Spake2.leInt(raw.copyOfRange(8, 264)))
            // The same key and certificate come back from storage.
            val again = AdbKey.loadOrCreate(dir)
            assertArrayEquals(key.certificate.encoded, again.certificate.encoded)
            key.certificate.verify(key.publicKey)
        } finally {
            dir.deleteRecursively()
        }
    }
}
