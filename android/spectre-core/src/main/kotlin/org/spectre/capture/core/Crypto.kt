// SPECTRE Capture — spectre-core
// Crypto primitives shared by the deposit pipeline (JCA only: available on
// Android API 21+ and on every JVM).
package org.spectre.capture.core

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object Hex {
    private val DIGITS = "0123456789abcdef".toCharArray()

    fun encode(bytes: ByteArray): String {
        val out = CharArray(bytes.size * 2)
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xff
            out[2 * i] = DIGITS[v ushr 4]
            out[2 * i + 1] = DIGITS[v and 0x0f]
        }
        return String(out)
    }

    fun decode(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(hex[2 * i], 16)
            val lo = Character.digit(hex[2 * i + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }
}

/** Size + SHA-256 + MD5 of the ORIGINAL bytes. MD5 is never used alone (size must also match). */
data class FileFingerprint(val size: Long, val sha256: String, val md5: String) {
    fun normalized() = FileFingerprint(size, sha256.lowercase(), md5.lowercase())
}

/** Incremental SHA-256 + MD5 over a byte stream (constant memory, multi-GB safe). */
class StreamingDigest {
    private val sha = MessageDigest.getInstance("SHA-256")
    private val md5 = MessageDigest.getInstance("MD5")
    var byteCount: Long = 0
        private set

    fun update(data: ByteArray, off: Int = 0, len: Int = data.size) {
        sha.update(data, off, len)
        md5.update(data, off, len)
        byteCount += len
    }

    fun finish(): FileFingerprint = FileFingerprint(byteCount, Hex.encode(sha.digest()), Hex.encode(md5.digest()))

    companion object {
        fun fingerprint(file: File, chunkSize: Int = 4 * 1024 * 1024): FileFingerprint {
            val d = StreamingDigest()
            FileInputStream(file).use { input ->
                val buf = ByteArray(chunkSize)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n > 0) d.update(buf, 0, n)
                }
            }
            return d.finish()
        }
    }
}

object SpectreCrypto {
    private val random = SecureRandom()

    fun hmacSha256Hex(key: ByteArray, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return Hex.encode(mac.doFinal(message.toByteArray(Charsets.UTF_8)))
    }

    fun sha256Hex(data: ByteArray): String = Hex.encode(MessageDigest.getInstance("SHA-256").digest(data))

    fun sha256Hex(text: String): String = sha256Hex(text.toByteArray(Charsets.UTF_8))

    /** Constant-time comparison for MACs / secrets. */
    fun constantTimeEquals(a: String, b: String): Boolean {
        val x = a.toByteArray(Charsets.UTF_8)
        val y = b.toByteArray(Charsets.UTF_8)
        if (x.size != y.size) return false
        var diff = 0
        for (i in x.indices) diff = diff or (x[i].toInt() xor y[i].toInt())
        return diff == 0
    }

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also { random.nextBytes(it) }
}
