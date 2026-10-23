package app.strongroom.android.security

import java.math.BigInteger

/** Uncompressed SEC1 encoding of P-256 points (0x04 || X || Y, 65 bytes). */
object Sec1 {
    const val LENGTH = 65
    private const val COORD = 32

    fun encode(x: BigInteger, y: BigInteger): ByteArray {
        val out = ByteArray(LENGTH)
        out[0] = 0x04
        fixed(x).copyInto(out, 1)
        fixed(y).copyInto(out, 1 + COORD)
        return out
    }

    /** Returns (x, y) or throws [IllegalArgumentException]. */
    fun decode(bytes: ByteArray): Pair<BigInteger, BigInteger> {
        require(bytes.size == LENGTH && bytes[0] == 0x04.toByte()) { "not an uncompressed SEC1 P-256 point" }
        val x = BigInteger(1, bytes.copyOfRange(1, 1 + COORD))
        val y = BigInteger(1, bytes.copyOfRange(1 + COORD, LENGTH))
        return x to y
    }

    private fun fixed(v: BigInteger): ByteArray {
        require(v.signum() >= 0) { "negative coordinate" }
        val raw = v.toByteArray()
        return when {
            raw.size == COORD -> raw
            raw.size == COORD + 1 && raw[0] == 0.toByte() -> raw.copyOfRange(1, raw.size)
            raw.size < COORD -> ByteArray(COORD - raw.size) + raw
            else -> throw IllegalArgumentException("coordinate too large")
        }
    }
}
