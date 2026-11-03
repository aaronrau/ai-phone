package ai.local.receptionist.adb

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * SPAKE2 over edwards25519, byte-compatible with BoringSSL's spake25519.c,
 * which adbd uses for Wireless debugging pairing. Includes BoringSSL's
 * "password scalar hack" (the password scalar is made a multiple of eight by
 * adding multiples of the group order), because both peers must compute the
 * same mask points.
 *
 * Plain BigInteger arithmetic: pairing runs once, so speed and constant-time
 * behaviour do not matter here.
 */
class Spake2(
    private val alice: Boolean,
    private val myName: ByteArray,
    private val theirName: ByteArray,
    random: SecureRandom = SecureRandom(),
) {
    private val privateKey: BigInteger
    private lateinit var passwordScalar: BigInteger
    private lateinit var passwordHash: ByteArray
    private lateinit var myMessage: ByteArray

    init {
        val seed = ByteArray(64).also { random.nextBytes(it) }
        // x25519_sc_reduce, then left_shift_3 (clears the cofactor later).
        privateKey = leInt(seed).mod(L).shiftLeft(3)
    }

    /** Returns this side's 32-byte message. */
    fun generateMessage(password: ByteArray): ByteArray {
        passwordHash = sha512(password)
        var scalar = leInt(passwordHash).mod(L)
        var order = L
        for (bit in 0 until 3) {
            if (scalar.testBit(bit)) scalar = scalar.add(order)
            order = order.shiftLeft(1)
        }
        passwordScalar = scalar
        val mask = Point.mul(passwordScalar, if (alice) M else N)
        val pStar = Point.mul(privateKey, Point.BASE).add(mask)
        myMessage = pStar.encode()
        return myMessage
    }

    /** Returns the 64-byte shared key, or throws if [theirMessage] is not a curve point. */
    fun processMessage(theirMessage: ByteArray): ByteArray {
        require(theirMessage.size == 32) { "SPAKE2 message must be 32 bytes" }
        val qStar = Point.decode(theirMessage) ?: throw IllegalArgumentException("peer point is not on the curve")
        val peersMask = Point.mul(passwordScalar, if (alice) N else M)
        val shared = Point.mul(privateKey, qStar.add(peersMask.negate())).encode()
        val sha = MessageDigest.getInstance("SHA-512")
        fun put(bytes: ByteArray) {
            val length = ByteArray(8)
            var n = bytes.size.toLong()
            for (i in 0 until 8) { length[i] = (n and 0xff).toByte(); n = n ushr 8 }
            sha.update(length)
            sha.update(bytes)
        }
        if (alice) {
            put(myName); put(theirName); put(myMessage); put(theirMessage)
        } else {
            put(theirName); put(myName); put(theirMessage); put(myMessage)
        }
        put(shared)
        put(passwordHash)
        return sha.digest()
    }

    /** A point in extended twisted Edwards coordinates (a = -1). */
    class Point(val x: BigInteger, val y: BigInteger, val z: BigInteger, val t: BigInteger) {
        fun add(o: Point): Point {
            val a = y.subtract(x).multiply(o.y.subtract(o.x)).mod(P)
            val b = y.add(x).multiply(o.y.add(o.x)).mod(P)
            val c = t.multiply(D2).multiply(o.t).mod(P)
            val d = z.multiply(TWO).multiply(o.z).mod(P)
            val e = b.subtract(a); val f = d.subtract(c); val g = d.add(c); val h = b.add(a)
            return Point(e.multiply(f).mod(P), g.multiply(h).mod(P), f.multiply(g).mod(P), e.multiply(h).mod(P))
        }

        fun negate() = Point(P.subtract(x).mod(P), y, z, P.subtract(t).mod(P))

        fun encode(): ByteArray {
            val zi = z.modInverse(P)
            val ax = x.multiply(zi).mod(P)
            val ay = y.multiply(zi).mod(P)
            val out = leBytes(ay, 32)
            if (ax.testBit(0)) out[31] = (out[31].toInt() or 0x80).toByte()
            return out
        }

        companion object {
            fun affine(x: BigInteger, y: BigInteger) = Point(x, y, BigInteger.ONE, x.multiply(y).mod(P))
            val IDENTITY = Point(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)
            val BASE = affine(
                BigInteger("15112221349535400772501151409588531511454012693041857206046113283949847762202"),
                BigInteger("46316835694926478169428394003475163141307993866256225615783033603165251855960"),
            )

            /** Full (unreduced) scalar multiplication: SPAKE2's scalars exceed the group order. */
            fun mul(k: BigInteger, point: Point): Point {
                var result = IDENTITY
                for (i in k.bitLength() - 1 downTo 0) {
                    result = result.add(result)
                    if (k.testBit(i)) result = result.add(point)
                }
                return result
            }

            /** Decodes like ed25519.py's decodepoint (and ref10's frombytes): null if off the curve. */
            fun decode(bytes: ByteArray): Point? {
                val copy = bytes.copyOf()
                val sign = (copy[31].toInt() ushr 7) and 1
                copy[31] = (copy[31].toInt() and 0x7f).toByte()
                val y = leInt(copy).mod(P)
                val yy = y.multiply(y).mod(P)
                val xx = yy.subtract(BigInteger.ONE).multiply(D.multiply(yy).add(BigInteger.ONE).modInverse(P)).mod(P)
                var x = xx.modPow(P.add(BigInteger.valueOf(3)).shiftRight(3), P)
                if (x.multiply(x).subtract(xx).mod(P).signum() != 0) x = x.multiply(SQRT_M1).mod(P)
                if (x.multiply(x).subtract(xx).mod(P).signum() != 0) return null
                if (x.testBit(0) != (sign == 1)) x = P.subtract(x).mod(P)
                return affine(x, y)
            }
        }
    }

    companion object {
        private val TWO = BigInteger.valueOf(2)
        val P: BigInteger = TWO.pow(255).subtract(BigInteger.valueOf(19))
        val L: BigInteger = TWO.pow(252).add(BigInteger("27742317777372353535851937790883648493"))
        private val D: BigInteger = BigInteger.valueOf(-121665).multiply(BigInteger.valueOf(121666).modInverse(P)).mod(P)
        private val D2: BigInteger = D.multiply(TWO).mod(P)
        private val SQRT_M1: BigInteger = TWO.modPow(P.subtract(BigInteger.ONE).shiftRight(2), P)

        /** BoringSSL's fixed points, derived from these seeds by repeated SHA-256 until one decodes. */
        val M: Point = generatePoint("edwards25519 point generation seed (M)")
        val N: Point = generatePoint("edwards25519 point generation seed (N)")

        fun generatePoint(seed: String): Point {
            val sha = MessageDigest.getInstance("SHA-256")
            var v = sha.digest(seed.toByteArray(Charsets.US_ASCII))
            while (true) {
                Point.decode(v)?.let { return it }
                v = sha.digest(v)
            }
        }

        fun sha512(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-512").digest(bytes)

        fun leInt(bytes: ByteArray): BigInteger = BigInteger(1, bytes.reversedArray())

        fun leBytes(value: BigInteger, size: Int): ByteArray {
            val be = value.toByteArray()
            val out = ByteArray(size)
            for (i in 0 until minOf(size, be.size)) out[i] = be[be.size - 1 - i]
            return out
        }
    }
}
