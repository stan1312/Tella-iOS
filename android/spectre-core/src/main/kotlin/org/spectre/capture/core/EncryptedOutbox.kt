// SPECTRE Capture — spectre-core
// Encrypted outbox: holds the ORIGINAL bytes until the deposit is verified.
// Format "SPXO1" (identical to iOS): header + fixed-size segments, each sealed
// with AES-256-GCM under a random per-capture key kept in the SecretStore
// (Android Keystore-wrapped on device). Segment nonce = 4 zero bytes ‖
// big-endian segment index; AAD = header ‖ index ‖ last-flag, so truncation /
// reordering is detected. Deleting the key is a cryptographic erasure.
package org.spectre.capture.core

import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class EncryptedOutbox(val directory: File, private val secrets: SecretStore, val segmentSize: Int = 1 shl 20) {
    companion object {
        val MAGIC = "SPXO1".toByteArray(Charsets.US_ASCII)
        const val HEADER_SIZE = 5 + 4 + 8
        const val TAG_SIZE = 16

        fun header(segmentSize: Int, plaintextSize: Long): ByteArray =
            ByteBuffer.allocate(HEADER_SIZE).put(MAGIC).putInt(segmentSize).putLong(plaintextSize).array()

        fun parseHeader(h: ByteArray): Pair<Int, Long> {
            if (h.size != HEADER_SIZE || !h.copyOfRange(0, 5).contentEquals(MAGIC)) throw SpectreException.OutboxCorrupted()
            val b = ByteBuffer.wrap(h, 5, 12)
            val seg = b.int
            val size = b.long
            if (seg < 4096 || size < 0) throw SpectreException.OutboxCorrupted()
            return seg to size
        }

        fun segmentCount(total: Long, segmentSize: Int): Long = if (total == 0L) 1 else (total + segmentSize - 1) / segmentSize

        fun nonce(index: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(index).array()

        fun aad(header: ByteArray, index: Long, last: Boolean): ByteArray =
            ByteBuffer.allocate(header.size + 9).put(header).putLong(index).put(if (last) 1 else 0).array()
    }

    /** Applied to every container created (platform-specific protection). */
    var didCreateFile: ((File) -> Unit)? = null

    init {
        require(segmentSize >= 4096)
        directory.mkdirs()
    }

    fun containerFile(id: String) = File(directory, "outbox-$id.spxo")

    private fun cipher(mode: Int, key: ByteArray, index: Long, aad: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_SIZE * 8, nonce(index)))
            updateAAD(aad)
        }

    /** Streams [plaintext] into a new encrypted container; returns the fingerprint of the ORIGINAL bytes. */
    fun importPlaintext(plaintext: File, captureId: String): FileFingerprint =
        plaintext.inputStream().use { importStream(it, plaintext.length(), captureId) }

    /**
     * Streams [input] (exactly [total] bytes, e.g. a decrypted Tella vault stream)
     * into a new encrypted container and returns the fingerprint of those bytes.
     */
    fun importStream(input: InputStream, total: Long, captureId: String): FileFingerprint {
        if (!Validation.isUUID(captureId)) throw SpectreException.InvalidCaptureId()
        if (total < 0) throw SpectreException.OutboxCorrupted()
        directory.mkdirs()   // may have been wiped (quick delete)
        val key = SpectreCrypto.randomBytes(32)
        secrets.set(SecretKeys.outboxKey(captureId), key)
        val out = containerFile(captureId)
        val digest = StreamingDigest()
        try {
            FileOutputStream(out).use { w ->
                didCreateFile?.invoke(out)
                val header = header(segmentSize, total)
                w.write(header)
                val segCount = segmentCount(total, segmentSize)
                val buf = ByteArray(segmentSize)
                for (index in 0 until segCount) {
                    val want = minOf(segmentSize.toLong(), total - index * segmentSize).toInt().coerceAtLeast(0)
                    var got = 0
                    while (got < want) {
                        val n = input.read(buf, got, want - got)
                        if (n < 0) throw SpectreException.OutboxCorrupted()   // source shorter than announced
                        got += n
                    }
                    digest.update(buf, 0, got)
                    val c = cipher(Cipher.ENCRYPT_MODE, key, index, aad(header, index, index == segCount - 1))
                    w.write(c.doFinal(buf, 0, got))   // ciphertext ‖ tag
                }
                w.flush()
                w.fd.sync()
            }
        } catch (e: Exception) {
            runCatching { destroy(captureId) }
            throw if (e is SpectreException) e else SpectreException.OutboxCorrupted()
        } finally {
            java.util.Arrays.fill(key, 0)
        }
        val fp = digest.finish()
        if (fp.size != total) { runCatching { destroy(captureId) }; throw SpectreException.OutboxCorrupted() }
        return fp
    }

    fun plaintextSize(id: String): Long = RandomAccessFile(containerFile(id), "r").use { f ->
        val h = ByteArray(HEADER_SIZE); f.readFully(h); parseHeader(h).second
    }

    /** Returns decrypted bytes [offset, offset+length) of the original file; every segment touched is authenticated. */
    fun readPlaintext(id: String, offset: Long, length: Int): ByteArray {
        val key = secrets.get(SecretKeys.outboxKey(id)) ?: throw SpectreException.OutboxKeyMissing()
        try {
            RandomAccessFile(containerFile(id), "r").use { f ->
                val header = ByteArray(HEADER_SIZE)
                try { f.readFully(header) } catch (e: java.io.EOFException) { throw SpectreException.OutboxCorrupted() }
                val (seg, total) = parseHeader(header)
                if (offset < 0 || offset > total) throw SpectreException.OutboxRange()
                val end = minOf(total, offset + maxOf(0, length))
                if (end == offset) return ByteArray(0)
                val segCount = segmentCount(total, seg)
                val result = ByteArray((end - offset).toInt())
                var written = 0
                var index = offset / seg
                while (index * seg < end) {
                    val plainStart = index * seg
                    val plainLen = minOf(seg.toLong(), total - plainStart).toInt()
                    val fileOffset = HEADER_SIZE.toLong() + index * (seg + TAG_SIZE)
                    val blob = ByteArray(plainLen + TAG_SIZE)
                    f.seek(fileOffset)
                    try { f.readFully(blob) } catch (e: java.io.EOFException) { throw SpectreException.OutboxCorrupted() }
                    val plain = try {
                        cipher(Cipher.DECRYPT_MODE, key, index, aad(header, index, index == segCount - 1)).doFinal(blob)
                    } catch (e: AEADBadTagException) { throw SpectreException.OutboxCorrupted() }
                    catch (e: java.security.GeneralSecurityException) { throw SpectreException.OutboxCorrupted() }
                    val lo = (maxOf(offset, plainStart) - plainStart).toInt()
                    val hi = (minOf(end, plainStart + plainLen) - plainStart).toInt()
                    System.arraycopy(plain, lo, result, written, hi - lo)
                    written += hi - lo
                    index++
                }
                return result
            }
        } catch (e: java.io.FileNotFoundException) {
            throw SpectreException.OutboxCorrupted()
        } finally {
            java.util.Arrays.fill(key, 0)
        }
    }

    /** Re-hashes the whole container. */
    fun fingerprint(id: String, chunk: Int = 4 shl 20): FileFingerprint {
        val total = plaintextSize(id)
        val d = StreamingDigest()
        var off = 0L
        while (off < total) {
            val part = readPlaintext(id, off, chunk)
            d.update(part); off += part.size
        }
        return d.finish()
    }

    fun exists(id: String): Boolean = containerFile(id).exists()
    fun hasKey(id: String): Boolean = secrets.get(SecretKeys.outboxKey(id)) != null

    /** Cryptographic erasure (delete key first) then file removal. */
    fun destroy(id: String) {
        secrets.delete(SecretKeys.outboxKey(id))
        val f = containerFile(id)
        if (f.exists() && !f.delete()) throw java.io.IOException("outbox delete failed")
    }
}
