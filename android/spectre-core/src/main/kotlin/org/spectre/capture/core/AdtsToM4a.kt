// SPECTRE Capture — spectre-core
// Tella Android's dictaphone writes raw AAC in ADTS framing ("audio/aac").
// The deposit backend (unchanged from iOS) accepts audio as "audio/mp4" (.m4a),
// so recordings are re-wrapped, WITHOUT re-encoding, into an MP4 container:
// every AAC access unit is copied byte for byte (only the 7/9-byte ADTS
// headers are dropped and replaced by the MP4 sample tables).
//
// Two passes over the source, no plaintext temp file:
//   1. AdtsToM4a.scan(input)        → frame sizes + audio config (+ exact output size)
//   2. AdtsToM4a.M4aInputStream(...) → the .m4a bytes, generated on the fly
// so the result can be streamed straight into the encrypted outbox.
package org.spectre.capture.core

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream

object AdtsToM4a {
    private val SAMPLE_RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)

    class Plan(
        val audioObjectType: Int,      // ADTS profile + 1 (2 = AAC-LC)
        val samplingIndex: Int,
        val channelConfig: Int,
        val frameSizes: IntArray       // payload sizes (without ADTS header)
    ) {
        val sampleRate: Int get() = SAMPLE_RATES[samplingIndex]
        val payloadBytes: Long get() = frameSizes.fold(0L) { a, b -> a + b }
        val durationUnits: Long get() = frameSizes.size.toLong() * 1024
        internal val head: ByteArray by lazy { ftyp() + mdatHeader(payloadBytes) }
        internal val moov: ByteArray by lazy { moov(this, head.size.toLong()) }   // samples start right after ftyp + mdat header
        /** Exact size of the .m4a that M4aInputStream will produce. */
        val outputSize: Long get() = head.size + payloadBytes + moov.size
    }

    /** Pass 1: validates the ADTS stream and records every frame size. */
    fun scan(input: InputStream): Plan {
        val sizes = ArrayList<Int>()
        var aot = -1; var sfi = -1; var ch = -1
        val hdr = ByteArray(9)
        while (true) {
            val first = readFully(input, hdr, 0, 7, allowEof = true)
            if (first == 0) break
            val h = parseHeader(hdr)
            if (h.protectionAbsent == 0) readFully(input, hdr, 7, 2, allowEof = false)
            if (aot < 0) { aot = h.profile + 1; sfi = h.samplingIndex; ch = h.channelConfig }
            else if (aot != h.profile + 1 || sfi != h.samplingIndex || ch != h.channelConfig) throw IOException("ADTS parameters change mid-stream")
            val payload = h.frameLength - h.headerLength
            if (payload <= 0) throw IOException("bad ADTS frame length")
            skipFully(input, payload.toLong())
            sizes.add(payload)
        }
        if (sizes.isEmpty()) throw IOException("no ADTS frame")
        if (sfi !in SAMPLE_RATES.indices) throw IOException("unsupported sampling index")
        return Plan(aot, sfi, ch, sizes.toIntArray())
    }

    /** Pass 2: the .m4a bytes. [source] must be the same ADTS stream as the one scanned. */
    class M4aInputStream(private val source: InputStream, private val plan: Plan) : InputStream() {
        private var phase = 0          // 0 head, 1 frames, 2 moov, 3 done
        private var cur: ByteArray = plan.head
        private var pos = 0
        private var frame = 0
        private val hdr = ByteArray(9)

        private fun advance(): Boolean {
            while (pos >= cur.size) {
                when (phase) {
                    0 -> { phase = 1; frame = 0; nextFrameOrMoov() }
                    1 -> nextFrameOrMoov()
                    2 -> { phase = 3; return false }
                    else -> return false
                }
            }
            return true
        }

        private fun nextFrameOrMoov() {
            if (frame >= plan.frameSizes.size) {
                if (source.read() != -1) throw IOException("ADTS source longer than scanned")
                phase = 2; cur = plan.moov; pos = 0; return
            }
            readFully(source, hdr, 0, 7, allowEof = false)
            val h = parseHeader(hdr)
            if (h.protectionAbsent == 0) readFully(source, hdr, 7, 2, allowEof = false)
            val payload = h.frameLength - h.headerLength
            if (payload != plan.frameSizes[frame]) throw IOException("ADTS source differs from scan")
            val b = ByteArray(payload)
            readFully(source, b, 0, payload, allowEof = false)
            cur = b; pos = 0; frame++
        }

        override fun read(): Int {
            if (!advance()) return -1
            return cur[pos++].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (!advance()) return -1
            val n = minOf(len, cur.size - pos)
            System.arraycopy(cur, pos, b, off, n)
            pos += n
            return n
        }

        override fun close() = source.close()
    }

    // ---------------------------------------------------------------- ADTS

    private class Header(val profile: Int, val samplingIndex: Int, val channelConfig: Int,
                         val protectionAbsent: Int, val frameLength: Int) {
        val headerLength: Int get() = if (protectionAbsent == 1) 7 else 9
    }

    private fun parseHeader(b: ByteArray): Header {
        val b0 = b[0].toInt() and 0xff; val b1 = b[1].toInt() and 0xff; val b2 = b[2].toInt() and 0xff
        val b3 = b[3].toInt() and 0xff; val b4 = b[4].toInt() and 0xff; val b5 = b[5].toInt() and 0xff
        val b6 = b[6].toInt() and 0xff
        if (b0 != 0xff || (b1 and 0xf0) != 0xf0) throw IOException("ADTS sync lost")
        if ((b1 and 0x06) != 0) throw IOException("not AAC (layer != 0)")
        val protectionAbsent = b1 and 0x01
        val profile = (b2 ushr 6) and 0x03
        val sfi = (b2 ushr 2) and 0x0f
        val ch = ((b2 and 0x01) shl 2) or ((b3 ushr 6) and 0x03)
        val frameLength = ((b3 and 0x03) shl 11) or (b4 shl 3) or ((b5 ushr 5) and 0x07)
        val rawBlocks = b6 and 0x03
        if (rawBlocks != 0) throw IOException("multiple raw data blocks per ADTS frame not supported")
        if (ch == 0) throw IOException("channel configuration 0 not supported")
        return Header(profile, sfi, ch, protectionAbsent, frameLength)
    }

    private fun readFully(input: InputStream, b: ByteArray, off: Int, len: Int, allowEof: Boolean): Int {
        var got = 0
        while (got < len) {
            val n = input.read(b, off + got, len - got)
            if (n < 0) {
                if (allowEof && got == 0) return 0
                throw IOException("truncated ADTS stream")
            }
            got += n
        }
        return got
    }

    private fun skipFully(input: InputStream, n: Long) {
        var left = n
        val tmp = ByteArray(4096)
        while (left > 0) {
            val r = input.read(tmp, 0, minOf(left, tmp.size.toLong()).toInt())
            if (r < 0) throw IOException("truncated ADTS frame")
            left -= r
        }
    }

    // ---------------------------------------------------------------- MP4 boxes

    private fun box(type: String, body: ByteArray): ByteArray {
        val o = ByteArrayOutputStream(body.size + 8)
        DataOutputStream(o).apply { writeInt(body.size + 8); writeBytes(type); write(body) }
        return o.toByteArray()
    }

    private fun fullBox(type: String, version: Int, flags: Int, body: ByteArray): ByteArray =
        box(type, bytes { writeInt((version shl 24) or flags); write(body) })

    private inline fun bytes(block: DataOutputStream.() -> Unit): ByteArray {
        val o = ByteArrayOutputStream(); DataOutputStream(o).block(); return o.toByteArray()
    }

    private fun ftyp() = box("ftyp", bytes { writeBytes("M4A "); writeInt(0); writeBytes("M4A "); writeBytes("mp42"); writeBytes("isom") })

    private fun mdatHeader(payload: Long): ByteArray {
        if (payload + 8 > 0xFFFFFFFFL) throw IOException("recording too large for a 32-bit mdat")
        return bytes { writeInt((payload + 8).toInt()); writeBytes("mdat") }
    }

    private val MATRIX = intArrayOf(0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000)

    private fun descriptor(tag: Int, body: ByteArray): ByteArray {
        require(body.size < 128)
        return byteArrayOf(tag.toByte(), body.size.toByte()) + body
    }

    private fun moov(p: Plan, dataOffset: Long): ByteArray {
        val dur = p.durationUnits
        val rate = p.sampleRate
        if (dur > 0xFFFFFFFFL) throw IOException("recording too long")
        val maxFrame = p.frameSizes.maxOrNull() ?: 0
        val avgBitrate = if (dur > 0) (p.payloadBytes * 8 * rate / dur).toInt() else 0

        val mvhd = fullBox("mvhd", 0, 0, bytes {
            writeInt(0); writeInt(0); writeInt(rate); writeInt(dur.toInt())
            writeInt(0x00010000); writeShort(0x0100); writeShort(0); writeInt(0); writeInt(0)
            MATRIX.forEach { writeInt(it) }
            repeat(6) { writeInt(0) }
            writeInt(2)                                   // next track id
        })
        val tkhd = fullBox("tkhd", 0, 3, bytes {
            writeInt(0); writeInt(0); writeInt(1); writeInt(0); writeInt(dur.toInt())
            writeInt(0); writeInt(0); writeShort(0); writeShort(0); writeShort(0x0100); writeShort(0)
            MATRIX.forEach { writeInt(it) }
            writeInt(0); writeInt(0)
        })
        val mdhd = fullBox("mdhd", 0, 0, bytes {
            writeInt(0); writeInt(0); writeInt(rate); writeInt(dur.toInt()); writeShort(0x55c4); writeShort(0)
        })
        val hdlr = fullBox("hdlr", 0, 0, bytes {
            writeInt(0); writeBytes("soun"); writeInt(0); writeInt(0); writeInt(0); writeBytes("SoundHandler"); writeByte(0)
        })
        val smhd = fullBox("smhd", 0, 0, bytes { writeShort(0); writeShort(0) })
        val dinf = box("dinf", fullBox("dref", 0, 0, bytes { writeInt(1); write(fullBox("url ", 0, 1, ByteArray(0))) }))

        val asc = byteArrayOf(
            ((p.audioObjectType shl 3) or (p.samplingIndex ushr 1)).toByte(),
            (((p.samplingIndex and 1) shl 7) or (p.channelConfig shl 3)).toByte()
        )
        val decConfig = descriptor(0x04, bytes {
            writeByte(0x40)                               // MPEG-4 audio
            writeByte(0x15)                               // audio stream
            writeByte((maxFrame ushr 16) and 0xff); writeShort(maxFrame and 0xffff)
            writeInt(avgBitrate); writeInt(avgBitrate)
            write(descriptor(0x05, asc))
        })
        val esd = descriptor(0x03, bytes { writeShort(1); writeByte(0); write(decConfig); write(descriptor(0x06, byteArrayOf(0x02))) })
        val esds = fullBox("esds", 0, 0, esd)
        val mp4a = box("mp4a", bytes {
            repeat(6) { writeByte(0) }; writeShort(1)     // data reference index
            writeInt(0); writeInt(0)
            writeShort(p.channelConfig.coerceAtMost(2)); writeShort(16); writeShort(0); writeShort(0)
            writeInt(if (rate <= 0xffff) rate shl 16 else 0)
            write(esds)
        })
        val stsd = fullBox("stsd", 0, 0, bytes { writeInt(1); write(mp4a) })
        val stts = fullBox("stts", 0, 0, bytes { writeInt(1); writeInt(p.frameSizes.size); writeInt(1024) })
        val stsc = fullBox("stsc", 0, 0, bytes { writeInt(1); writeInt(1); writeInt(p.frameSizes.size); writeInt(1) })
        val stsz = fullBox("stsz", 0, 0, bytes { writeInt(0); writeInt(p.frameSizes.size); p.frameSizes.forEach { writeInt(it) } })
        val stco = if (dataOffset <= 0xFFFFFFFFL) fullBox("stco", 0, 0, bytes { writeInt(1); writeInt(dataOffset.toInt()) })
                   else fullBox("co64", 0, 0, bytes { writeInt(1); writeLong(dataOffset) })
        val stbl = box("stbl", stsd + stts + stsc + stsz + stco)
        val minf = box("minf", smhd + dinf + stbl)
        val mdia = box("mdia", mdhd + hdlr + minf)
        val trak = box("trak", tkhd + mdia)
        return box("moov", mvhd + trak)
    }
}
