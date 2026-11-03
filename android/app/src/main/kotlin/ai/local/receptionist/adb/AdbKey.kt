package ai.local.receptionist.adb

import java.io.ByteArrayOutputStream
import java.io.File
import java.math.BigInteger
import java.net.Socket
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAPublicKeySpec
import java.security.interfaces.RSAPrivateCrtKey
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509ExtendedTrustManager

/**
 * This app's adb identity: an RSA-2048 key (like a computer's ~/.android/adbkey)
 * kept in app-private storage, plus a self-signed certificate for adb's TLS.
 * Whoever holds the key can open a shell on this phone while Wireless
 * debugging is on, so it never leaves [directory].
 */
class AdbKey private constructor(val privateKey: PrivateKey, val publicKey: RSAPublicKey, val certificate: X509Certificate) {
    companion object {
        private const val NAME = "receptionist@aiphone"

        fun exists(directory: File) = File(directory, "adbkey").isFile

        fun loadOrCreate(directory: File): AdbKey {
            val file = File(directory, "adbkey")
            val encoded = if (file.isFile) file.readBytes() else {
                directory.mkdirs()
                val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
                val tmp = File(directory, "adbkey.tmp")
                tmp.writeBytes(pair.private.encoded)
                tmp.setReadable(false, false); tmp.setReadable(true, true)
                check(tmp.renameTo(file)) { "could not store the adb key" }
                pair.private.encoded
            }
            val factory = KeyFactory.getInstance("RSA")
            val private = factory.generatePrivate(PKCS8EncodedKeySpec(encoded)) as RSAPrivateCrtKey
            val public = factory.generatePublic(RSAPublicKeySpec(private.modulus, private.publicExponent)) as RSAPublicKey
            return AdbKey(private, public, selfSignedCertificate(private, public))
        }

        // ------------------------------------------------------------ DER

        private fun der(tag: Int, vararg parts: ByteArray): ByteArray {
            val body = ByteArrayOutputStream().apply { parts.forEach { write(it) } }.toByteArray()
            val out = ByteArrayOutputStream()
            out.write(tag)
            val n = body.size
            when {
                n < 0x80 -> out.write(n)
                n < 0x100 -> { out.write(0x81); out.write(n) }
                n < 0x10000 -> { out.write(0x82); out.write(n shr 8); out.write(n and 0xff) }
                else -> { out.write(0x83); out.write(n shr 16); out.write((n shr 8) and 0xff); out.write(n and 0xff) }
            }
            out.write(body)
            return out.toByteArray()
        }

        private fun seq(vararg parts: ByteArray) = der(0x30, *parts)
        private fun integer(value: BigInteger) = der(0x02, value.toByteArray())
        private val sha256WithRsa = seq(der(0x06, byteArrayOf(0x2a, 0x86.toByte(), 0x48, 0x86.toByte(), 0xf7.toByte(),
            0x0d, 0x01, 0x01, 0x0b)), der(0x05))

        private fun name(common: String) = seq(der(0x31, seq(
            der(0x06, byteArrayOf(0x55, 0x04, 0x03)), der(0x0c, common.toByteArray(Charsets.UTF_8)))))

        private fun utcTime(date: Date): ByteArray {
            val format = SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
            return der(0x17, format.format(date).toByteArray(Charsets.US_ASCII))
        }

        private fun selfSignedCertificate(private: PrivateKey, public: RSAPublicKey): X509Certificate {
            // Fixed validity so the certificate is identical across loads.
            val notBefore = Date(1_577_836_800_000L) // 2020-01-01
            val subject = name("AI Phone")
            val tbs = seq(
                der(0xa0, integer(BigInteger.valueOf(2))),
                integer(BigInteger.ONE),
                sha256WithRsa,
                subject,
                seq(utcTime(notBefore), der(0x18, // GeneralizedTime: UTCTime ends in 2049
                     "20991231235959Z".toByteArray(Charsets.US_ASCII))),
                subject,
                public.encoded,
            )
            val signature = Signature.getInstance("SHA256withRSA").run { initSign(private); update(tbs); sign() }
            val certificate = seq(tbs, sha256WithRsa, der(0x03, byteArrayOf(0) + signature))
            return CertificateFactory.getInstance("X.509")
                .generateCertificate(certificate.inputStream()) as X509Certificate
        }
    }

    /**
     * The public key as adb sends it while pairing: base64 of the mincrypt
     * RSAPublicKey struct, then " name" and a NUL (adb's adbkey.pub format).
     */
    fun adbPublicKey(): ByteArray {
        val n = publicKey.modulus
        val words = 2048 / 32
        val r32 = BigInteger.ONE.shiftLeft(32)
        val n0inv = n.mod(r32).modInverse(r32).negate().mod(r32)
        val rr = BigInteger.ONE.shiftLeft(4096).mod(n)
        val out = ByteArrayOutputStream()
        fun u32(value: Long) { for (i in 0 until 4) out.write(((value ushr (8 * i)) and 0xff).toInt()) }
        u32(words.toLong())
        u32(n0inv.toLong())
        out.write(Spake2.leBytes(n, 256))
        out.write(Spake2.leBytes(rr, 256))
        u32(publicKey.publicExponent.toLong())
        val base64 = Base64.getEncoder().encode(out.toByteArray())
        return base64 + " $NAME\u0000".toByteArray(Charsets.US_ASCII)
    }

    /** TLS 1.3 client context presenting this key. adbd's certificate is self-signed, so any is accepted. */
    fun sslContext(): SSLContext {
        val keyManager = object : X509ExtendedKeyManager() {
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = "adb"
            override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = "adb"
            override fun getCertificateChain(alias: String?) = arrayOf(certificate)
            override fun getPrivateKey(alias: String?) = privateKey
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf("adb")
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = null
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = null
        }
        val trustAll = object : X509ExtendedTrustManager() {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) {}
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) {}
            override fun getAcceptedIssuers() = arrayOf<X509Certificate>()
        }
        return SSLContext.getInstance("TLSv1.3").apply { init(arrayOf(keyManager), arrayOf(trustAll), SecureRandom()) }
    }
}
