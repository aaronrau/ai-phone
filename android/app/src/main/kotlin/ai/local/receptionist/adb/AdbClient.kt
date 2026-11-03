package ai.local.receptionist.adb

import android.net.ssl.SSLSockets
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SSLSocket

/**
 * A minimal adb client for this phone's own Wireless debugging: pairing
 * (Android 11+ pairing code) and running shell commands as the shell user.
 *
 * Only the loopback address is ever contacted; this is the app's sole use of
 * the INTERNET permission, and nothing leaves the phone.
 */
object AdbClient {
    private val LOOPBACKS: List<InetAddress> = listOf(
        InetAddress.getByAddress("localhost", byteArrayOf(127, 0, 0, 1)),
        InetAddress.getByAddress("localhost", ByteArray(16).also { it[15] = 1 }), // ::1
    )
    private val LOOPBACK = LOOPBACKS.first()
    private const val TIMEOUT_MS = 10_000

    /** Connects to adbd on IPv4 loopback, falling back to IPv6 loopback. */
    private fun connect(port: Int): Socket {
        var failure: java.io.IOException? = null
        for (address in LOOPBACKS) {
            val socket = Socket()
            try {
                socket.soTimeout = TIMEOUT_MS
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(address, port), TIMEOUT_MS)
                return socket
            } catch (e: java.io.IOException) {
                runCatching { socket.close() }
                failure = e
            }
        }
        throw failure!!
    }

    // ------------------------------------------------------------ pairing

    class PairingException(message: String) : Exception(message)

    private val CLIENT_NAME = "adb pair client\u0000".toByteArray(Charsets.US_ASCII)
    private val SERVER_NAME = "adb pair server\u0000".toByteArray(Charsets.US_ASCII)
    private const val EXPORTED_KEY_LABEL = "adb-label\u0000"
    private const val PEER_INFO_SIZE = 8192
    private const val PACKET_SPAKE2 = 0
    private const val PACKET_PEER_INFO = 1

    /**
     * Pairs [key] with the pairing service on [port] using the six-digit
     * [code] shown under Wireless debugging → Pair device with pairing code.
     * Throws [PairingException] when the code is wrong.
     */
    fun pair(port: Int, code: String, key: AdbKey) {
        val raw = connect(port)
        val tls = key.sslContext().socketFactory.createSocket(raw, LOOPBACK.hostAddress, port, true) as SSLSocket
        tls.use { socket ->
            socket.enabledProtocols = arrayOf("TLSv1.3")
            socket.startHandshake()
            val exported = SSLSockets.exportKeyingMaterial(socket, EXPORTED_KEY_LABEL, null, 64)
                ?: throw PairingException("TLS key export unavailable")
            val input = DataInputStream(socket.inputStream)
            val output = socket.outputStream

            val spake = Spake2(alice = true, myName = CLIENT_NAME, theirName = SERVER_NAME)
            writePairingPacket(output, PACKET_SPAKE2, spake.generateMessage(code.toByteArray(Charsets.US_ASCII) + exported))
            val theirMessage = readPairingPacket(input, PACKET_SPAKE2)
            val cipher = PairingCipher(spake.processMessage(theirMessage))

            val peerInfo = ByteArray(PEER_INFO_SIZE)
            peerInfo[0] = 0 // ADB_RSA_PUB_KEY
            key.adbPublicKey().copyInto(peerInfo, 1)
            writePairingPacket(output, PACKET_PEER_INFO, cipher.encrypt(peerInfo))
            val reply = try { readPairingPacket(input, PACKET_PEER_INFO) }
                catch (_: EOFException) { throw PairingException("wrong pairing code") }
            try { cipher.decrypt(reply) } catch (_: Exception) { throw PairingException("wrong pairing code") }
        }
    }

    private fun writePairingPacket(output: OutputStream, type: Int, payload: ByteArray) {
        val header = ByteBuffer.allocate(6).order(ByteOrder.BIG_ENDIAN)
            .put(1.toByte()).put(type.toByte()).putInt(payload.size).array()
        output.write(header + payload)
        output.flush()
    }

    private fun readPairingPacket(input: DataInputStream, expectedType: Int): ByteArray {
        val header = ByteArray(6).also { input.readFully(it) }
        val type = header[1].toInt()
        val size = ByteBuffer.wrap(header, 2, 4).order(ByteOrder.BIG_ENDIAN).int
        if (header[0].toInt() != 1 || type != expectedType || size !in 1..PEER_INFO_SIZE * 2) {
            throw PairingException("unexpected pairing packet (version ${header[0]}, type $type, $size bytes)")
        }
        return ByteArray(size).also { input.readFully(it) }
    }

    /** adb's pairing AES-128-GCM: HKDF-SHA256 key, 64-bit little-endian counter nonces per direction. */
    private class PairingCipher(secret: ByteArray) {
        private val key: SecretKeySpec
        private var encryptCounter = 0L
        private var decryptCounter = 0L

        init {
            val info = "adb pairing_auth aes-128-gcm key".toByteArray(Charsets.US_ASCII)
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
            val prk = mac.doFinal(secret)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            key = SecretKeySpec(mac.doFinal(info + byteArrayOf(1)).copyOf(16), "AES")
        }

        private fun nonce(counter: Long) = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putLong(counter).array()

        fun encrypt(plain: ByteArray): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce(encryptCounter++)))
            doFinal(plain)
        }

        fun decrypt(sealed: ByteArray): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce(decryptCounter++)))
            doFinal(sealed)
        }
    }

    // ------------------------------------------------------------ shell

    private const val A_CNXN = 0x4e584e43
    private const val A_OPEN = 0x4e45504f
    private const val A_OKAY = 0x59414b4f
    private const val A_CLSE = 0x45534c43
    private const val A_WRTE = 0x45545257
    private const val A_STLS = 0x534c5453
    private const val A_AUTH = 0x48545541
    private const val A_VERSION = 0x01000001
    private const val A_STLS_VERSION = 0x01000000
    private const val MAX_PAYLOAD = 256 * 1024

    private class Message(val command: Int, val arg0: Int, val arg1: Int, val data: ByteArray)

    private fun write(output: OutputStream, command: Int, arg0: Int, arg1: Int, data: ByteArray = ByteArray(0)) {
        var checksum = 0
        for (b in data) checksum += b.toInt() and 0xff
        val header = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(command).putInt(arg0).putInt(arg1).putInt(data.size).putInt(checksum).putInt(command.inv())
            .array()
        output.write(header + data)
        output.flush()
    }

    private fun read(input: InputStream): Message {
        val data = DataInputStream(input)
        val header = ByteArray(24).also { data.readFully(it) }
        val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        val command = buffer.int; val arg0 = buffer.int; val arg1 = buffer.int; val length = buffer.int
        buffer.int
        if (buffer.int != command.inv() || length !in 0..MAX_PAYLOAD * 4) throw IllegalStateException("bad adb packet")
        return Message(command, arg0, arg1, ByteArray(length).also { data.readFully(it) })
    }

    class NotPairedException : Exception("this app is not paired with Wireless debugging")

    /**
     * Runs [command] as the shell user through adbd's TLS port and returns its
     * output. Throws [NotPairedException] if adbd rejects this app's key.
     */
    fun shell(port: Int, key: AdbKey, command: String): String {
        connect(port).use { raw ->
            write(raw.getOutputStream(), A_CNXN, A_VERSION, MAX_PAYLOAD, "host::\u0000".toByteArray())
            val hello = read(raw.getInputStream())
            if (hello.command == A_AUTH) throw NotPairedException()
            check(hello.command == A_STLS) { "adbd did not offer TLS (0x${Integer.toHexString(hello.command)})" }
            write(raw.getOutputStream(), A_STLS, A_STLS_VERSION, 0)
            val tls = key.sslContext().socketFactory.createSocket(raw, LOOPBACK.hostAddress, port, true) as SSLSocket
            tls.use { socket ->
                socket.enabledProtocols = arrayOf("TLSv1.3")
                try { socket.startHandshake() } catch (failure: javax.net.ssl.SSLException) { throw NotPairedException() }
                val input = socket.inputStream
                val output = socket.outputStream
                var message = try { read(input) } catch (_: Exception) { throw NotPairedException() }
                while (message.command != A_CNXN) {
                    if (message.command == A_AUTH) throw NotPairedException()
                    message = read(input)
                }
                val localId = 1
                write(output, A_OPEN, localId, 0, "shell:$command\u0000".toByteArray(Charsets.UTF_8))
                val result = ByteArrayOutputStream()
                var remoteId = 0
                while (true) {
                    message = try { read(input) } catch (_: EOFException) { break }
                    when (message.command) {
                        A_OKAY -> remoteId = message.arg0
                        A_WRTE -> {
                            result.write(message.data)
                            write(output, A_OKAY, localId, message.arg0)
                        }
                        A_CLSE -> {
                            if (remoteId != 0) write(output, A_CLSE, localId, remoteId)
                            break
                        }
                    }
                }
                return result.toString(Charsets.UTF_8.name())
            }
        }
    }
}
